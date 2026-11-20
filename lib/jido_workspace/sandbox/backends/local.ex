defmodule Jido.Workspace.Sandbox.Backends.Local do
  @moduledoc "OS processes under the controller user. This backend has no OS security isolation."
  @behaviour Jido.Workspace.Sandbox.Backend
  alias Jido.Workspace.Sandbox
  alias Jido.Workspace.Sandbox.Backends.Erlexec
  alias Jido.Workspace.Sandbox.Files

  @impl true
  def open(sandbox, []), do: open(sandbox, runner: :port)

  def open(sandbox, runner: :port),
    do: {:ok, sandbox, Map.put(capabilities(:direct_child), :stdin, :pipe)}

  def open(sandbox, runner: :erlexec) do
    with :ok <- Erlexec.available() do
      {:ok, {sandbox, :erlexec}, capabilities(:process_group)}
    end
  end

  def open(_, _), do: {:error, :invalid_backend_options}

  defp capabilities(cancellation) do
    %{
      provider: :local,
      isolation: :process,
      files: :local,
      exec: true,
      services: true,
      beam_call: true,
      checkpoints: false,
      tunnels: false,
      cancellation: cancellation,
      network: :host,
      runtime_limits: %{}
    }
  end

  @impl true
  def start_service({sandbox, :erlexec}, %{kind: :exec} = spec),
    do: start_exec(sandbox, spec, :erlexec)

  def start_service({sandbox, :erlexec}, spec), do: start(spec, sandbox)
  def start_service(sandbox, spec), do: start(spec, sandbox)

  @impl true
  def finish_service(_, service, code) do
    {:ok, %{service | status: :exited, exit_status: code} |> Map.delete(:cleanup_error)}
  end

  @impl true
  def stop_service({_, :erlexec}, %{runner: :erlexec, status: :running} = service),
    do: Erlexec.stop(service)

  def stop_service(%Sandbox{}, %{kind: :exec, status: :running, handle: port}) do
    signal_child(port)

    receive do
      {^port, {:exit_status, _}} = exit ->
        # Release can still fail after the child exits. Keep its exit record.
        send(self(), exit)
        :ok
    after
      1_000 -> {:error, :cleanup_unconfirmed}
    end
  end

  def stop_service(_, service), do: stop(service)
  @impl true
  def destroy(_), do: :ok

  defp start(%{kind: :beam} = spec, sandbox) do
    with {:ok, dir} <- Files.path(sandbox.root, Map.get(spec, :dir, ".")) do
      opts = %{
        connection: :standard_io,
        args: Enum.map(Map.get(spec, :args, []), &String.to_charlist/1),
        exec:
          {~c"/bin/sh",
           [
             ~c"-c",
             ~c"cd \"$1\" && shift && exec \"$@\"",
             ~c"jido-sandbox",
             String.to_charlist(dir),
             :os.find_executable(~c"erl")
           ]},
        env: [
          {~c"PWD", String.to_charlist(dir)}
          | Enum.map(Map.get(spec, :env, []), fn {key, value} ->
              {String.to_charlist(key), String.to_charlist(value)}
            end)
        ],
        wait_boot: 20_000
      }

      try do
        case :peer.start_link(opts) do
          {:ok, peer, _} ->
            :ok = :peer.call(peer, :file, :set_cwd, [String.to_charlist(dir)])
            os_pid = :peer.call(peer, :os, :getpid, []) |> List.to_string() |> String.to_integer()

            {:ok,
             %{
               kind: :beam,
               handle: peer,
               status: :running,
               os_pid: os_pid,
               output: "",
               exit_status: nil
             }}

          error ->
            error
        end
      catch
        kind, reason -> {:error, {:beam_start, kind, reason}}
      end
    end
  end

  defp start(%{kind: :exec} = spec, sandbox), do: start_exec(sandbox, spec, :port)
  defp start(_, _), do: {:error, :unsupported_service}

  defp start_exec(sandbox, %{executable: command} = spec, runner) do
    with {:ok, dir} <- Files.path(sandbox.root, Map.get(spec, :dir, ".")),
         executable when is_binary(executable) <- System.find_executable(command),
         {:ok, transport} <- start_transport(runner, executable, dir, spec) do
      {:ok,
       Map.merge(
         %{
           kind: :exec,
           status: :running,
           output: "",
           truncated: false,
           output_limit: Map.get(spec, :output_limit, 65_536),
           exit_status: nil
         },
         transport
       )}
    else
      nil -> {:error, :executable_not_found}
      error -> error
    end
  end

  defp start_transport(:erlexec, executable, dir, spec), do: Erlexec.start(executable, dir, spec)

  defp start_transport(:port, executable, dir, spec) do
    try do
      opts = [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, Map.get(spec, :args, [])},
        {:cd, dir},
        {:env,
         Enum.map(Map.get(spec, :env, []), fn {k, v} ->
           {String.to_charlist(k), String.to_charlist(v)}
         end)}
      ]

      opts = if spec[:stdin] == :closed, do: [:in | opts], else: opts
      port = Port.open({:spawn_executable, String.to_charlist(executable)}, opts)

      # A short process can exit before Port.info/2. Its output and exit
      # status are still in the controller mailbox and must be collected.
      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          nil -> nil
        end

      {:ok, %{handle: port, os_pid: os_pid}}
    rescue
      error -> {:error, {:exec_start, Exception.message(error)}}
    end
  end

  defp stop(%{status: status}) when status != :running, do: :ok

  defp stop(%{kind: :beam, handle: peer}) do
    try do
      :peer.stop(peer)
    catch
      :exit, _ -> :ok
    end
  end

  defp stop(%{kind: :exec, handle: port}) do
    signal_child(port)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp signal_child(port) do
    # Read the PID from the live port. A stored PID can outlive its process.
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end
  end
end
