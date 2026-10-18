defmodule Jido.Workspace.TestSupport.ProcessBackend do
  @moduledoc "Shell test backend that runs a real local process."
  @behaviour Jido.Shell.Backend

  def init(config), do: {:ok, config}
  def cwd(state), do: {:ok, "/", state}
  def cd(state, _), do: {:ok, state}
  def terminate(_), do: :ok
  def cancel(_, pid), do: Task.Supervisor.terminate_child(Jido.Shell.CommandTaskSupervisor, pid)

  def execute(state, command, [], _) do
    {:ok, pid} =
      Task.Supervisor.start_child(Jido.Shell.CommandTaskSupervisor, fn ->
        {output, status} = System.cmd("/bin/sh", ["-c", command], stderr_to_stdout: true)
        send(state.session_pid, {:command_event, {:output, output}})

        result =
          if status == 0,
            do: {:ok, :done},
            else: {:error, Jido.Shell.Error.command(:exit_code, %{exit_code: status})}

        send(state.session_pid, {:command_finished, result})
      end)

    {:ok, pid, state}
  end
end
