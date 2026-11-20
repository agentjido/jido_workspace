defmodule Jido.Workspace.Examples.DisposableSandbox do
  @moduledoc "Copy a report inside a disposable workspace."

  alias Jido.Workspace

  def copy_report(workspace, report) do
    with :ok <- Workspace.write(workspace, "input.txt", report),
         {:ok, %{status: :exited, exit_status: 0}} <-
           Workspace.run(workspace, ["/bin/cp", "input.txt", "report.txt"]) do
      Workspace.save(workspace)
    else
      {:ok, execution} -> {:error, execution}
      {:error, _} = error -> error
    end
  end
end
