defmodule Jido.Workspace.Sandbox.Backends.Docker do
  @moduledoc """
  Local Docker containers with a workspace directory mounted at `/workspace`.

  The image must be installed. Select `runtime: "runsc"` for gVisor. This
  backend never installs a runtime, pulls an image, or falls back to Local.
  Each service has its own container. Only workspace files persist across calls.
  """
  @behaviour Jido.Workspace.Sandbox.Backend
  alias Jido.Workspace.Sandbox.Backends.Local
  alias Jido.Workspace.Sandbox.Files

  @label "dev.jido.workspace.sandbox"
  @checkout_label "dev.jido.workspace.checkout"
  @never_started "0001-01-01T00:00:00Z"
  @cpu_count 1
  @runtime_limits %{
    cpu_millicores: @cpu_count * 1_000,
    memory_bytes: 256 * 1024 * 1024,
    pids: 256,
    tmp_bytes: 64 * 1024 * 1024
  }
  @info_format """
  {{.CgroupDriver}} {{.MemoryLimit}} {{.PidsLimit}} {{and .CPUCfsQuota .CPUCfsPeriod}}
  {{range $name, $_ := .Runtimes}}{{$name}} {{end}}
  """

  @impl true
  def open(sandbox, opts) do
    image = Keyword.get(opts, :image)
    runtime = Keyword.get(opts, :runtime, "runc")
    read_only = Keyword.get(opts, :workspace_read_only, false)

    with true <-
           Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:image, :runtime, :workspace_read_only] == [],
         true <- is_boolean(read_only),
         true <- not String.contains?(sandbox.root, [",", "\"", "\n", "\r"]),
         true <- is_binary(image) and image != "" and not String.starts_with?(image, "-"),
         true <- runtime in ["runc", "runsc"],
         docker when is_binary(docker) <- System.find_executable("docker"),
         {:ok, endpoint} <- local_endpoint(docker),
         client = {docker, endpoint},
         :ok <- checkout_available(client, sandbox.checkout_key),
         {:ok, info} <- command(client, ["info", "--format", @info_format]),
         {:ok, runtime_limits} <- runtime_limits(info, runtime),
         {:ok, image_id} <- image_id(client, image),
         {:ok, volumes} <-
           command(client, ["image", "inspect", "--format", "{{len .Config.Volumes}}", image_id]),
         :ok <- no_volumes(volumes),
         {uid, 0} <- System.cmd("/usr/bin/id", ["-u"]),
         {gid, 0} <- System.cmd("/usr/bin/id", ["-g"]),
         {:ok, reservation} <- reserve_checkout(client, sandbox, image_id) do
      state = %{
        sandbox: sandbox,
        docker: client,
        image: image_id,
        runtime: runtime,
        workspace_read_only: read_only,
        reservation: reservation,
        user: String.trim(uid) <> ":" <> String.trim(gid)
      }

      {:ok, state,
       %{
         provider: if(runtime == "runsc", do: :gvisor, else: :docker),
         isolation: if(runtime == "runsc", do: :gvisor, else: :container),
         runtime: runtime,
         image: image_id,
         files: :local_bind,
         exec: true,
         services: true,
         beam_call: false,
         checkpoints: false,
         tunnels: false,
         cancellation: :container,
         network: :disabled,
         stdin: :pipe,
         runtime_limits: runtime_limits
       }}
    else
      false -> {:error, :invalid_backend_options}
      nil -> {:error, {:backend_unavailable, :docker, :cli_not_found}}
      {:error, {:docker, _, _, _} = detail} -> {:error, {:backend_unavailable, :docker, detail}}
      error -> error
    end
  end

  @impl true
  def start_service(state, %{kind: :exec} = spec) do
    name =
      "jido-" <>
        state.sandbox.id <> "-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with {:ok, directory} <- Files.path(state.sandbox.root, Map.get(spec, :dir, ".")),
         true <- File.dir?(directory) do
      relative = Path.relative_to(directory, state.sandbox.root)
      workdir = if relative == ".", do: "/workspace", else: "/workspace/" <> relative
      mount = workspace_mount(state)
      env = Enum.flat_map(Map.get(spec, :env, []), fn {k, v} -> ["--env", k <> "=" <> v] end)
      stdin = if spec[:stdin] == :pipe, do: ["--interactive"], else: []

      args =
        ["create"] ++
          stdin ++
          labels(state.sandbox) ++
          [
            "--name",
            name,
            "--pull",
            "never",
            "--runtime",
            state.runtime,
            "--network",
            "none",
            "--read-only",
            "--tmpfs",
            "/tmp:rw,nosuid,nodev,size=" <> Integer.to_string(@runtime_limits.tmp_bytes),
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--pids-limit",
            Integer.to_string(@runtime_limits.pids),
            "--memory",
            Integer.to_string(@runtime_limits.memory_bytes),
            "--cpus",
            Integer.to_string(@cpu_count),
            "--user",
            state.user,
            "--no-healthcheck",
            "--log-driver",
            "none",
            "--mount",
            mount,
            "--workdir",
            workdir,
            "--entrypoint",
            spec.executable
          ] ++
          env ++ [state.image] ++ Map.get(spec, :args, [])

      result =
        with {:ok, _} <- command(state.docker, args),
             {:ok, service} <-
               Local.start_service(
                 state.sandbox,
                 %{
                   spec
                   | executable: elem(state.docker, 0),
                     args:
                       ["--host", elem(state.docker, 1), "start", "--attach"] ++ stdin ++ [name]
                 }
                 |> Map.put(:env, [{"DOCKER_CONTEXT", ""}, {"DOCKER_HOST", elem(state.docker, 1)}])
                 |> Map.put(:dir, ".")
               ) do
          service = Map.merge(service, %{container: name, os_pid: nil})
          {:ok, attach_connector(service, state.docker, spec[:connector])}
        end

      case result do
        {:ok, _} ->
          result

        {:error, reason} = error ->
          case remove(state, [name]) do
            :ok -> start_error(reason)
            cleanup -> {:error, {:start_cleanup_failed, error, cleanup}}
          end
      end
    else
      false -> {:error, :enoent}
      error -> error
    end
  end

  def start_service(_, _), do: {:error, {:unsupported_capability, :beam_call}}

  defp attach_connector(service, _, nil), do: service

  defp attach_connector(service, docker, program) do
    args = ["exec", "--interactive", "--workdir", "/", service.container, program, "127.0.0.1"]
    Map.put(service, :connector, client_arguments(docker, args))
  end

  # A rejected create did not reach the attach and start call.
  defp start_error({:docker, "create", status, _} = reason) when is_integer(status),
    do: {:error, {:start_failed, reason}}

  defp start_error(reason), do: {:error, reason}

  defp workspace_mount(state) do
    # The root path has already been checked for mount CSV delimiters.
    mount = "type=bind,source=" <> state.sandbox.root <> ",target=/workspace"

    if state.workspace_read_only,
      do: mount <> ",readonly,bind-recursive=disabled",
      else: mount
  end

  @impl true
  def finish_service(state, service, client_code) do
    with {:ok, inspection} <-
           command(state.docker, [
             "inspect",
             "--format",
             "{{.State.StartedAt}}\n{{.State.Status}}\n{{.State.ExitCode}}\n{{.State.Error}}",
             service.container
           ]),
         [started_at, status] <- String.split(inspection, "\n", parts: 2) do
      failure = {:docker, "start", client_code, String.trim(status)}

      # Docker can report exit code 127 even when the executable never started.
      case String.split(status, "\n", parts: 3) do
        [phase, _, _]
        when phase in ["created", "exited"] and started_at == @never_started and client_code != 0 ->
          with :ok <- remove(state, [service.container]), do: {:error, {:start_failed, failure}}

        ["exited", code, _] when started_at != @never_started ->
          {:ok, %{service | status: :exited, exit_status: String.to_integer(code)}}

        _ ->
          with :ok <- remove(state, [service.container]), do: {:error, failure}
      end
    else
      [_] -> {:error, :invalid_container_state}
      error -> error
    end
  end

  @impl true
  def stop_service(state, service) do
    with :ok <- remove(state, [service.container]), do: Local.stop_service(nil, service)
  end

  @impl true
  def destroy(state) do
    with {:ok, names} <-
           command(
             state.docker,
             [
               "ps",
               "--all",
               "--format",
               "{{.Names}}",
               "--filter",
               "label=" <> @label <> "=" <> state.sandbox.id
             ]
           ),
         names = String.split(names),
         :ok <- remove(state, List.delete(names, state.reservation)) do
      if state.reservation in names, do: remove(state, [state.reservation]), else: :ok
    end
  end

  defp reserve_checkout(_, %{checkout_key: nil}, _), do: {:ok, nil}

  defp reserve_checkout(client, sandbox, image) do
    # Docker holds the name even if the BEAM or the controller exits.
    name = "jido-checkout-" <> sandbox.checkout_key

    args =
      ["create", "--name", name] ++
        labels(sandbox) ++
        ["--pull", "never", "--network", "none", "--entrypoint", "/bin/false", image]

    case command(client, args) do
      {:ok, _} ->
        {:ok, name}

      error ->
        with :ok <- checkout_available(client, sandbox.checkout_key), do: error
    end
  end

  defp checkout_available(_, nil), do: :ok

  defp checkout_available(client, key) do
    with {:ok, output} <-
           command(client, [
             "ps",
             "--all",
             "--quiet",
             "--filter",
             "label=" <> @checkout_label <> "=" <> key
           ]) do
      if String.trim(output) == "", do: :ok, else: {:error, :checkout_busy}
    end
  end

  defp labels(sandbox) do
    args = ["--label", @label <> "=" <> sandbox.id]

    if key = sandbox.checkout_key,
      do: args ++ ["--label", @checkout_label <> "=" <> key],
      else: args
  end

  defp remove(_, []), do: :ok

  defp remove(state, ids) do
    case command(state.docker, ["rm", "--force", "--volumes"] ++ ids) do
      {:ok, _} ->
        :ok

      {:error, {:docker, _, code, output}} = error when is_integer(code) ->
        # A completed cleanup can be repeated after an explicit stop.
        lines = String.split(output, "\n", trim: true)

        if lines != [] and
             Enum.all?(lines, fn line ->
               line in ids or
                 String.starts_with?(line, "Error response from daemon: No such container:")
             end), do: :ok, else: error

      error ->
        error
    end
  end

  defp runtime_limits(info, runtime) do
    case String.split(info, "\n", parts: 2) do
      [features, runtimes] ->
        if runtime in String.split(runtimes),
          do: {:ok, resource_ceilings(runtime, String.split(features))},
          else: {:error, {:runtime_unavailable, runtime}}

      [_] ->
        {:error, {:backend_unavailable, :docker, :invalid_info}}
    end
  end

  defp resource_ceilings("runc", [driver | features]) when driver in ["cgroupfs", "systemd"] do
    for {key, "true"} <- Enum.zip([:memory_bytes, :pids, :cpu_millicores], features),
        into: %{tmp_bytes: @runtime_limits.tmp_bytes} do
      {key, Map.fetch!(@runtime_limits, key)}
    end
  end

  defp resource_ceilings("runc", _), do: %{tmp_bytes: @runtime_limits.tmp_bytes}
  defp resource_ceilings("runsc", _), do: %{}

  defp no_volumes(volumes) do
    if String.trim(volumes) == "0",
      do: :ok,
      else: {:error, {:unsupported_capability, :image_volumes}}
  end

  defp image_id(docker, image) do
    case command(docker, ["image", "inspect", "--format", "{{.Id}}", image]) do
      {:ok, id} ->
        {:ok, String.trim(id)}

      {:error, {:docker, _, status, _}} when is_integer(status) ->
        {:error, {:image_unavailable, image}}

      error ->
        error
    end
  end

  defp local_endpoint(docker) do
    endpoint =
      cond do
        System.get_env("DOCKER_CONTEXT", "") != "" ->
          command(docker, [
            "context",
            "inspect",
            System.get_env("DOCKER_CONTEXT"),
            "--format",
            "{{.Endpoints.docker.Host}}"
          ])

        System.get_env("DOCKER_HOST", "") != "" ->
          {:ok, System.get_env("DOCKER_HOST")}

        true ->
          command(docker, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
      end

    with {:ok, host} <- endpoint do
      if String.starts_with?(String.trim(host), "unix://"),
        do: {:ok, String.trim(host)},
        else: {:error, {:backend_unavailable, :docker, :local_engine_required}}
    end
  end

  # Keep control commands bounded. Service output is bounded by the controller.
  defp command(docker, [operation | _] = args) do
    {executable, args, env} = client_arguments(docker, args)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args}, {:env, env}]
      )

    collect(port, operation, "", System.monotonic_time(:millisecond) + 15_000)
  rescue
    error -> {:error, {:backend_unavailable, :docker, Exception.message(error)}}
  end

  defp client_arguments({executable, endpoint}, args) do
    {executable, ["--host", endpoint] ++ args,
     [{~c"DOCKER_CONTEXT", false}, {~c"DOCKER_HOST", false}]}
  end

  defp client_arguments(executable, args), do: {executable, args, []}

  defp collect(port, operation, output, deadline, truncated \\ false) do
    receive do
      {^port, {:data, bytes}} ->
        remaining = max(4096 - byte_size(output), 0)

        collect(
          port,
          operation,
          output <> binary_part(bytes, 0, min(byte_size(bytes), remaining)),
          deadline,
          truncated or byte_size(bytes) > remaining
        )

      {^port, {:exit_status, 0}} ->
        if truncated,
          do: {:error, {:docker, operation, :output_limit, output}},
          else: {:ok, output}

      {^port, {:exit_status, code}} ->
        {:error, {:docker, operation, code, output}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Local.stop_service(nil, %{kind: :exec, handle: port, status: :running})
        {:error, {:docker, operation, :timeout, output}}
    end
  end
end
