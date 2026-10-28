defmodule Jido.Workspace.Command do
  @moduledoc false
  alias Jido.Shell.ShellSessionServer, as: Session
  alias Jido.Workspace.{Error, Execution}

  # Each invocation has a separate subscriber mailbox and a fixed deadline.
  # Output limits apply while chunks arrive, before they enter the result.
  @doc "Runs one command with a private event subscriber, deadline, and output limit."
  def run(ws, id, pid, view, command, opts) do
    started = System.monotonic_time(:millisecond)
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    limit = Keyword.get(opts, :output_limit, 1_048_576)

    context =
      Keyword.get(opts, :execution_context, %{})
      |> Map.put(:max_runtime_ms, timeout)

    monitor = Process.monitor(pid)

    try do
      with {:ok, :subscribed} <- Session.subscribe(pid, self()),
           {:ok, :accepted} <- Session.run_command(pid, command, execution_context: context) do
        case collect(id, pid, monitor, command, started + timeout, limit, "", false, false) do
          {:ok, status, exit_status, output, truncated} ->
            after_files =
              case Jido.Workspace.file_view(ws) do
                {:ok, files} -> files
                error -> error
              end

            {:ok,
             %Execution{
               id: "execution-#{System.unique_integer([:positive, :monotonic])}",
               command: command,
               status: status,
               exit_status: exit_status,
               output: output,
               truncated: truncated,
               files: view,
               after_files: after_files,
               duration_ms: max(0, System.monotonic_time(:millisecond) - started)
             }}

          {:error, reason} ->
            failure(ws, reason)
        end
      else
        {:error, reason} -> failure(ws, reason)
      end
    after
      Process.demonitor(monitor, [:flush])
      safe_unsubscribe(pid)
    end
  catch
    :exit, _ -> failure(ws, :closed)
  end

  defp collect(id, pid, monitor, command, deadline, limit, output, truncated, started) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    if remaining == 0 do
      timed_out(pid, output, truncated)
    else
      receive do
        {:jido_shell_session, ^id, {:command_started, ^command}} ->
          collect(id, pid, monitor, command, deadline, limit, output, truncated, true)

        {:jido_shell_session, ^id, {stream, chunk}}
        when started and stream in [:output, :output_stderr] ->
          chunk = IO.iodata_to_binary(chunk)
          count = min(max(0, limit - byte_size(output)), byte_size(chunk))

          collect(
            id,
            pid,
            monitor,
            command,
            deadline,
            limit,
            output <> binary_part(chunk, 0, count),
            truncated or count < byte_size(chunk),
            started
          )

        {:jido_shell_session, ^id, :command_done} when started ->
          {:ok, :exited, 0, output, truncated}

        {:jido_shell_session, ^id, :command_cancelled} when started ->
          {:ok, :cancelled, nil, output, truncated}

        {:jido_shell_session, ^id,
         {:error, %Jido.Shell.Error{code: {:command, :exit_code}, context: ctx}}}
        when started ->
          {:ok, :exited, Map.get(ctx, :exit_code, Map.get(ctx, :code)), output, truncated}

        {:jido_shell_session, ^id, {:error, %Jido.Shell.Error{code: {:command, code}}}}
        when started and code in [:timeout, :runtime_limit_exceeded] ->
          {:ok, :timed_out, nil, output, truncated}

        # Shell broadcasts a refused concurrent request to all subscribers.
        # That event does not complete the command accepted by this worker.
        {:jido_shell_session, ^id, {:error, %Jido.Shell.Error{code: {:shell, :busy}}}}
        when started ->
          collect(id, pid, monitor, command, deadline, limit, output, truncated, started)

        {:jido_shell_session, ^id, {:error, reason}} when started ->
          {:error, reason}

        {:jido_shell_session, ^id, {:command_crashed, reason}} when started ->
          {:error, reason}

        {:DOWN, ^monitor, :process, ^pid, _} ->
          {:error, :closed}

        {:jido_shell_session, ^id, _} ->
          collect(id, pid, monitor, command, deadline, limit, output, truncated, started)
      after
        remaining ->
          timed_out(pid, output, truncated)
      end
    end
  end

  defp timed_out(pid, output, truncated) do
    Session.cancel(pid)
    {:ok, :timed_out, nil, output, truncated}
  end

  defp failure(ws, reason), do: {:error, Error.from_reason(:run, ws.id, reason)}

  defp safe_unsubscribe(pid) do
    Session.unsubscribe(pid, self())
  catch
    :exit, _ -> :ok
  end
end
