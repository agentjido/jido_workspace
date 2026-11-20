defmodule Jido.Workspace.Sandbox.Backends.Erlexec do
  @moduledoc false
  @compile {:no_warn_undefined, :exec}

  import Bitwise, only: [band: 2, bsr: 2]

  @cleanup_error {:error, :cleanup_unconfirmed}
  @start_timeout_ms 1_000
  @group_wait_ms 500

  def available do
    with :absent <- probe_group(2_147_483_647),
         {:ok, _} <- Application.ensure_all_started(:erlexec) do
      :ok
    else
      _ -> {:error, {:unsupported_capability, :process_group}}
    end
  end

  def start(executable, directory, spec) do
    owner = self()

    opts = [
      {:group, 0},
      :kill_group,
      {:stdin, :close},
      {:stdout, fn :stdout, _, bytes -> send(owner, {self(), {:data, bytes}}) end},
      {:stderr, :stdout},
      {:cd, directory},
      {:env, Map.get(spec, :env, [])}
    ]

    case :exec.run_link([executable | Map.get(spec, :args, [])], opts, @start_timeout_ms) do
      {:ok, handle, pid} ->
        {:ok, %{runner: :erlexec, handle: handle, os_pid: pid}}

      {:error, reason} ->
        {:error, {:start_failed, reason}}
    end
  catch
    # A lost start reply does not prove that the native program stayed idle.
    :exit, _ ->
      {:ok, %{runner: :erlexec, handle: nil, os_pid: nil, cleanup_error: @cleanup_error}}
  end

  def finish(service, reason) do
    case exit_code(reason) do
      {:ok, code} ->
        service = Map.put(service, :leader_exited, true)

        case wait_for_group(service.os_pid) do
          :ok -> %{service | status: :exited, exit_status: code} |> Map.delete(:cleanup_error)
          @cleanup_error -> Map.put(service, :cleanup_error, @cleanup_error)
        end

      :unknown ->
        Map.put(service, :cleanup_error, @cleanup_error)
    end
  end

  def stop(%{leader_exited: true, os_pid: pid}), do: wait_for_group(pid)
  def stop(%{handle: nil}), do: @cleanup_error

  def stop(%{handle: handle, os_pid: pid}) do
    if Process.alive?(handle), do: request_stop(handle)

    receive do
      {:EXIT, ^handle, reason} = exit ->
        # Keep the exit evidence if a later step in close fails.
        send(self(), exit)

        case exit_code(reason) do
          {:ok, _} -> wait_for_group(pid)
          :unknown -> @cleanup_error
        end
    after
      100 -> @cleanup_error
    end
  end

  defp request_stop(handle) do
    monitor = Process.monitor(handle)

    try do
      :exec.stop_and_wait(handle, @group_wait_ms)
    catch
      :exit, _ -> @cleanup_error
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp exit_code(:normal), do: {:ok, 0}

  defp exit_code({:exit_status, raw}) when is_integer(raw) and raw >= 0 do
    case band(raw, 0x7F) do
      0 -> {:ok, bsr(band(raw, 0xFF00), 8)}
      signal -> {:ok, 128 + signal}
    end
  end

  defp exit_code(_), do: :unknown

  defp wait_for_group(pid) do
    await_group(pid, System.monotonic_time(:millisecond) + @group_wait_ms)
  end

  defp await_group(pid, deadline) do
    case probe_group(pid) do
      :absent ->
        :ok

      :present ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_group(pid, deadline)
        else
          @cleanup_error
        end

      :unknown ->
        @cleanup_error
    end
  end

  defp probe_group(pid) when is_integer(pid) and pid > 1 do
    # Probe the group with signal zero. Never signal a stale group ID to stop it.
    # The shell builtin handles negative group IDs consistently on POSIX hosts.
    case System.cmd("/bin/sh", ["-c", ~S(kill -0 "$1"), "group-probe", "-#{pid}"],
           env: [{"LC_ALL", "C"}],
           stderr_to_stdout: true
         ) do
      {"", 0} ->
        :present

      {output, 1} ->
        if String.ends_with?(String.trim_trailing(output), "No such process"),
          do: :absent,
          else: :unknown

      _ ->
        :unknown
    end
  rescue
    ErlangError -> :unknown
  end

  defp probe_group(_), do: :unknown
end
