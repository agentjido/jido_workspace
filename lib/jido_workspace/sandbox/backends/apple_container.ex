defmodule Jido.Workspace.Sandbox.Backends.AppleContainer do
  @moduledoc """
  Apple Container runs each command in a Linux VM on Apple silicon.

  The host prepares the service, kernel, and image. Workspace supplies a single
  disposable bind mount at `/workspace` and removes the VM after use.
  """
  @behaviour Jido.Workspace.Sandbox.Backend

  alias Jido.Workspace.Sandbox.Backends.Local
  alias Jido.Workspace.Sandbox.Files

  @provider :apple_container
  @cli_timeout_ms 3_000
  @create_timeout_ms 12_000
  @cleanup_timeout_ms 5_000
  @retry_ms 75
  @control_output_limit 1_048_576

  @doc false
  def prepare(opts, host \\ host(), find_executable \\ &System.find_executable/1) do
    image = Keyword.get(opts, :image)
    read_only = Keyword.get(opts, :workspace_read_only, false)

    with true <- valid_image?(image) and is_boolean(read_only),
         :ok <- check_host(host),
         cli when is_binary(cli) <- find_executable.("container"),
         :ok <- check_service(cli),
         {:ok, reference, digest} <- local_image(cli, image) do
      {:ok, [cli: cli, image: reference, digest: digest, workspace_read_only: read_only]}
    else
      false -> {:error, :invalid_backend_options}
      nil -> unavailable(:cli_not_found)
      {:error, _} = error -> error
    end
  end

  defp valid_image?(image) when is_binary(image), do: image =~ ~r/\A[a-zA-Z0-9][^\s\x00]*\z/
  defp valid_image?(_), do: false

  defp host do
    {:os.type(), List.to_string(:erlang.system_info(:system_architecture)), :os.version()}
  end

  defp check_host({{:unix, :darwin}, "aarch64-apple-darwin" <> _, {major, _, _}})
       when major >= 26,
       do: :ok

  defp check_host(_), do: unavailable(:unsupported_host)

  defp check_service(cli) do
    with {:ok, output} <- command(cli, ["system", "status", "--format", "json"]),
         {:ok, %{"status" => "running", "client" => client, "server" => server}} <-
           Jason.decode(output) do
      if supported_version?(client) and supported_version?(server),
        do: :ok,
        else: unavailable(:unsupported_version)
    else
      _ -> unavailable(:service_unavailable)
    end
  end

  defp supported_version?(%{"version" => version}) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} -> Version.match?(parsed, ">= 1.7.1 and < 2.0.0")
      :error -> false
    end
  end

  defp supported_version?(_), do: false

  defp unavailable(reason), do: {:error, {:backend_unavailable, @provider, reason}}

  defp local_image(cli, image) do
    with {:ok, output} <- command(cli, ["image", "inspect", image]),
         {:ok,
          [
            %{
              "configuration" => %{"name" => reference, "descriptor" => %{"digest" => digest}},
              "variants" => variants
            }
          ]} <- Jason.decode(output),
         true <- valid_image?(reference) and is_binary(digest) and is_list(variants),
         true <-
           Enum.any?(
             variants,
             &match?(%{"platform" => %{"os" => "linux", "architecture" => "arm64"}}, &1)
           ) do
      {:ok, reference, digest}
    else
      _ -> {:error, {:image_unavailable, image}}
    end
  end

  @impl true
  def open(sandbox, opts) do
    if String.contains?(sandbox.root, [",", "\"", "\n", "\r", <<0>>]) do
      {:error, :invalid_backend_options}
    else
      {uid, 0} = System.cmd("/usr/bin/id", ["-u"])
      {gid, 0} = System.cmd("/usr/bin/id", ["-g"])

      state =
        opts
        |> Map.new()
        |> Map.put(:sandbox, sandbox)
        |> Map.put(:user, String.trim(uid) <> ":" <> String.trim(gid))

      {:ok, state,
       %{
         provider: @provider,
         isolation: :container,
         runtime: "container-runtime-linux",
         image: state.image,
         files: :local_bind,
         exec: true,
         services: false,
         beam_call: false,
         checkpoints: false,
         tunnels: false,
         cancellation: :container,
         network: :disabled,
         runtime_limits: %{}
       }}
    end
  end

  @impl true
  def start_service(state, %{kind: :exec} = spec) do
    with {:ok, directory} <- Files.path(state.sandbox.root, Map.get(spec, :dir, ".")),
         true <- File.dir?(directory),
         {:ok, _, digest} when digest == state.digest <- local_image(state.cli, state.image) do
      relative = Path.relative_to(directory, state.sandbox.root)
      workdir = if relative == ".", do: "/workspace", else: "/workspace/" <> relative
      id = "jido-apple-" <> state.sandbox.id <> "-" <> nonce()
      create(state, spec, id, workdir)
    else
      false -> {:error, {:start_failed, :enoent}}
      {:error, reason} -> {:error, {:start_failed, reason}}
      {:ok, _, _} -> {:error, {:start_failed, :image_changed}}
    end
  end

  def start_service(_, _), do: {:error, {:unsupported_capability, :beam_call}}

  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp create(state, spec, id, workdir) do
    mount = "type=bind,source=" <> state.sandbox.root <> ",target=/workspace"
    mount = if state.workspace_read_only, do: mount <> ",readonly", else: mount

    env =
      Enum.map(Map.get(spec, :env, []), fn {key, value} -> "--env=" <> key <> "=" <> value end)

    argv = Map.get(spec, :args, [])

    args =
      [
        "create",
        "--name",
        id,
        "--platform",
        "linux/arm64",
        "--runtime",
        "container-runtime-linux",
        "--network",
        "none",
        "--no-dns",
        "--read-only",
        "--cap-drop",
        "ALL",
        "--user",
        state.user,
        "--cpus",
        "1",
        "--memory",
        "256M",
        "--mount",
        mount,
        "--workdir",
        workdir,
        "--entrypoint=" <> spec.executable
      ] ++ env ++ [state.image | argv]

    case command(state.cli, args, @create_timeout_ms) do
      {:ok, output} ->
        if id in String.split(output, "\n", trim: true),
          do: attach(state, spec, id, workdir, argv),
          else: failed_launch(state, id, false)

      {:error, :cli_not_started} ->
        {:error, {:start_failed, :cli_not_started}}

      {:error, _} ->
        failed_launch(state, id, false)
    end
  end

  defp attach(state, spec, id, workdir, argv) do
    with {:ok, output} <- command(state.cli, ["inspect", id]),
         {:ok, [%{"id" => ^id, "configuration" => configuration}]} <- Jason.decode(output),
         true <- configured?(configuration, state, spec.executable, workdir, argv),
         {:ok, service} <-
           Local.start_service(state.sandbox, %{
             kind: :exec,
             executable: state.cli,
             args: ["start", "--attach", id],
             stdin: :closed,
             output_limit: Map.get(spec, :output_limit, 65_536)
           }) do
      {:ok, Map.merge(service, %{container: id, creation_confirmed: true, os_pid: nil})}
    else
      _ -> failed_launch(state, id, true)
    end
  end

  defp configured?(
         %{
           "image" => %{"descriptor" => %{"digest" => digest}},
           "initProcess" => %{
             "executable" => executable,
             "workingDirectory" => cwd,
             "arguments" => argv
           },
           "mounts" => [
             %{
               "source" => root,
               "destination" => "/workspace",
               "options" => options,
               "type" => %{"virtiofs" => _}
             }
           ],
           "networks" => [],
           "publishedPorts" => [],
           "publishedSockets" => [],
           "ssh" => false,
           "readOnly" => true,
           "capDrop" => ["ALL"],
           "runtimeHandler" => "container-runtime-linux"
         } = config,
         state,
         executable,
         cwd,
         argv
       ) do
    digest == state.digest and root == state.sandbox.root and is_nil(config["dns"]) and
      options == if(state.workspace_read_only, do: ["ro"], else: [])
  end

  defp configured?(_, _, _, _, _), do: false

  defp failed_launch(state, id, creation_confirmed) do
    case remove(state.cli, id, creation_confirmed) do
      :ok ->
        {:error, {:start_failed, :container_launch}}

      {:error, :quiescence_unknown} ->
        {:error, :quiescence_unknown,
         %{
           kind: :exec,
           handle: nil,
           container: id,
           creation_confirmed: creation_confirmed,
           status: :failed
         }}
    end
  end

  @impl true
  def finish_service(state, service, code) do
    with :ok <- remove(state.cli, service.container, service.creation_confirmed) do
      {:ok, %{service | status: :exited, exit_status: code}}
    end
  end

  @impl true
  def stop_service(_, %{status: status}) when status in [:exited, :stopped, :timed_out], do: :ok

  def stop_service(state, service) do
    with :ok <- Local.stop_service(nil, service) do
      remove(state.cli, service.container, service.creation_confirmed)
    end
  end

  @impl true
  def destroy(_), do: :ok

  defp remove(cli, id, creation_confirmed) do
    confirm_removal(cli, id, creation_confirmed, now() + @cleanup_timeout_ms)
  end

  defp confirm_removal(cli, id, known, deadline) do
    # Apple can reject deletion while the VM transitions through stopping.
    # Only a successful all-container query can confirm absence. After an
    # uncertain create, absence is meaningful once the ID has been observed.
    deleted =
      case command_until(cli, ["delete", "--force", id], min(now() + 1_500, deadline)) do
        {:ok, output} -> id in String.split(output, "\n", trim: true)
        _ -> false
      end

    listed =
      case command_until(cli, ["list", "--all", "--quiet"], min(now() + 1_500, deadline)) do
        {:ok, output} -> id in String.split(output, "\n", trim: true)
        _ -> :unknown
      end

    cond do
      listed == false and (known or deleted) ->
        :ok

      deadline - now() > @retry_ms ->
        Process.sleep(@retry_ms)
        confirm_removal(cli, id, known or deleted or listed == true, deadline)

      true ->
        {:error, :quiescence_unknown}
    end
  end

  defp command(cli, args, timeout \\ @cli_timeout_ms),
    do: command_until(cli, args, now() + timeout)

  defp command_until(cli, args, deadline) do
    if deadline > now() do
      with {:ok, port} <- open_control(cli, args), do: collect(port, [], 0, deadline)
    else
      {:error, :timeout}
    end
  end

  defp open_control(cli, args) do
    {:ok,
     Port.open(
       {:spawn_executable, cli},
       [:binary, :in, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args}]
     )}
  rescue
    ArgumentError -> {:error, :cli_not_started}
    ErlangError -> {:error, :cli_not_started}
  end

  defp collect(port, output, size, deadline) do
    receive do
      {^port, {:data, bytes}} ->
        size = size + byte_size(bytes)

        if size <= @control_output_limit and now() < deadline,
          do: collect(port, [bytes | output], size, deadline),
          else: abandon(port, :control_limit)

      {^port, {:exit_status, 0}} ->
        {:ok, output |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _}} ->
        {:error, :cli_failed}
    after
      max(deadline - now(), 0) -> abandon(port, :timeout)
    end
  end

  defp abandon(port, reason) do
    Local.stop_service(nil, %{kind: :exec, status: :running, handle: port})
    {:error, reason}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
