defmodule Jido.Workspace.Sandbox.Backends.Docker do
  @moduledoc """
  Local Docker containers with an owned directory mounted at `/workspace`.

  The image must be installed. Select `runtime: "runsc"` for gVisor. This
  backend never installs a runtime, pulls an image, or falls back to Local.
  Each service has its own container. Only workspace files persist across calls.
  """
  @behaviour Jido.Workspace.Sandbox.Backend
  alias Jido.Workspace.Sandbox.Backends.Local
  alias Jido.Workspace.Sandbox.Files

  @label "dev.jido.workspace.sandbox"

  @impl true
  def open(sandbox, opts) do
    image = Keyword.get(opts, :image)
    runtime = Keyword.get(opts, :runtime, "runc")

    with true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- [:image, :runtime] == [],
         true <- not String.contains?(sandbox.root, [",", "\"", "\n", "\r"]),
         true <- is_binary(image) and image != "" and not String.starts_with?(image, "-"),
         true <- runtime in ["runc", "runsc"],
         docker when is_binary(docker) <- System.find_executable("docker"),
         {:ok, endpoint} <- local_endpoint(docker),
         client = {docker, endpoint},
         {:ok, runtimes} <-
           command(client, [
             "info",
             "--format",
             "{{range $name, $_ := .Runtimes}}{{$name}} {{end}}"
           ]),
         :ok <- runtime_available(runtimes, runtime),
         {:ok, image_id} <- image_id(client, image),
         {:ok, volumes} <-
           command(client, ["image", "inspect", "--format", "{{len .Config.Volumes}}", image_id]),
         :ok <- no_volumes(volumes),
         {uid, 0} <- System.cmd("/usr/bin/id", ["-u"]),
         {gid, 0} <- System.cmd("/usr/bin/id", ["-g"]) do
      state = %{
        sandbox: sandbox,
        docker: client,
        image: image_id,
        runtime: runtime,
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
         network: :disabled
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
      # The mount CSV format must not interpret host path characters as options.
      mount = "type=bind,source=" <> state.sandbox.root <> ",target=/workspace"
      env = Enum.flat_map(Map.get(spec, :env, []), fn {k, v} -> ["--env", k <> "=" <> v] end)

      args =
        [
          "create",
          "--name",
          name,
          "--label",
          @label <> "=" <> state.sandbox.id,
          "--pull",
          "never",
          "--runtime",
          state.runtime,
          "--network",
          "none",
          "--read-only",
          "--tmpfs",
          "/tmp:rw,nosuid,nodev,size=64m",
          "--cap-drop",
          "ALL",
          "--security-opt",
          "no-new-privileges",
          "--pids-limit",
          "256",
          "--memory",
          "256m",
          "--cpus",
          "1",
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
                     args: ["--host", elem(state.docker, 1), "start", "--attach", name]
                 }
                 |> Map.put(:env, [{"DOCKER_CONTEXT", ""}, {"DOCKER_HOST", elem(state.docker, 1)}])
                 |> Map.put(:dir, ".")
               ) do
          {:ok, Map.merge(service, %{container: name, os_pid: nil})}
        end

      case result do
        {:ok, _} ->
          result

        error ->
          case remove(state, [name]) do
            :ok -> error
            cleanup -> {:error, {:start_cleanup_failed, error, cleanup}}
          end
      end
    else
      false -> {:error, :enoent}
      error -> error
    end
  end

  def start_service(_, _), do: {:error, {:unsupported_capability, :beam_call}}

  @impl true
  def finish_service(state, service, client_code) do
    with {:ok, status} <-
           command(state.docker, [
             "inspect",
             "--format",
             "{{.State.Status}}\n{{.State.ExitCode}}\n{{.State.Error}}",
             service.container
           ]) do
      case String.split(status, "\n", parts: 3) do
        ["exited", code, _] ->
          {:ok, %{service | status: :exited, exit_status: String.to_integer(code)}}

        _ ->
          with :ok <- remove(state, [service.container]),
               do: {:error, {:docker, "start", client_code, String.trim(status)}}
      end
    end
  end

  @impl true
  def stop_service(state, service) do
    with :ok <- remove(state, [service.container]), do: Local.stop_service(nil, service)
  end

  @impl true
  def destroy(state) do
    with {:ok, ids} <-
           command(
             state.docker,
             ["ps", "--all", "--quiet", "--filter", "label=" <> @label <> "=" <> state.sandbox.id]
           ) do
      case String.split(ids) do
        [] -> :ok
        ids -> remove(state, ids)
      end
    end
  end

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

  defp runtime_available(runtimes, runtime) do
    if runtime in String.split(runtimes),
      do: :ok,
      else: {:error, {:runtime_unavailable, runtime}}
  end

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
    {executable, args, env} =
      case docker do
        {executable, endpoint} ->
          {executable, ["--host", endpoint] ++ args,
           [{~c"DOCKER_CONTEXT", false}, {~c"DOCKER_HOST", false}]}

        executable ->
          {executable, args, []}
      end

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args}, {:env, env}]
      )

    collect(port, operation, "", System.monotonic_time(:millisecond) + 15_000)
  rescue
    error -> {:error, {:backend_unavailable, :docker, Exception.message(error)}}
  end

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
