defmodule Jido.Workspace.Examples.Report do
  @moduledoc "Write, copy, and read a report through one Workspace handle."

  alias Jido.Workspace

  def run(workspace, input) do
    with :ok <- Workspace.mkdir(workspace, "reports"),
         :ok <- Workspace.write(workspace, "reports/input data.txt", input),
         {:ok, %{exit_status: 0}} <-
           Workspace.run(workspace, ["cp", "input data.txt", "output data.txt"], cwd: "reports") do
      Workspace.read(workspace, "reports/output data.txt")
    else
      {:ok, %Workspace.Execution{} = execution} -> {:error, execution}
      error -> error
    end
  end
end
