defmodule Jido.Workspace.Sandbox.Backends.Local do
  @moduledoc "OS processes under the controller user. This backend has no OS security isolation."
  @behaviour Jido.Workspace.Sandbox.Backend
  alias Jido.Workspace.Sandbox.Files

  @impl true
  def open(sandbox, []) do
    {:ok, sandbox,
     %{
       provider: :local,
       isolation: :process,
       files: :local,
       exec: true,
       services: true,
       beam_call: true,
       checkpoints: false,
       tunnels: false,
       cancellation: :direct_child,
       network: :host
     }}
  end

  def open(_, _), do: {:error, :invalid_backend_options}

  @impl true
  def start_service(sandbox, spec), do: start(spec, sandbox)
  @impl true
  def finish_service(_, service, code), do: {:ok, %{service | status: :exited, exit_status: code}}
  @impl true
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

  defp start(%{kind: :exec, executable: command} = spec, sandbox) do
    with {:ok, dir} <- Files.path(sandbox.root, Map.get(spec, :dir, ".")),
         executable when is_binary(executable) <- System.find_executable(command) do
      try do
        port =
          Port.open({:spawn_executable, String.to_charlist(executable)}, [
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
          ])

        # A short process can exit before Port.info/2. Its output and exit
        # status are still in the controller mailbox and must be collected.
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            nil -> nil
          end

        {:ok,
         %{
           kind: :exec,
           handle: port,
           status: :running,
           os_pid: os_pid,
           output: "",
           truncated: false,
           output_limit: Map.get(spec, :output_limit, 65_536),
           exit_status: nil
         }}
      rescue
        error -> {:error, {:exec_start, Exception.message(error)}}
      end
    else
      nil -> {:error, :executable_not_found}
      error -> error
    end
  end

  defp start(_, _), do: {:error, :unsupported_service}

  defp stop(%{status: status}) when status != :running, do: :ok

  defp stop(%{kind: :beam, handle: peer}) do
    try do
      :peer.stop(peer)
    catch
      :exit, _ -> :ok
    end
  end

  defp stop(%{kind: :exec, handle: port}) do
    # Read the PID from the live port. A stored PID can outlive its process.
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end
