defmodule Jido.Workspace.Examples.ReadWithApprovedTool do
  alias Jido.Workspace
  alias Jido.Workspace.Execution

  def read(workspace, tool, path) do
    case Workspace.run(workspace, [tool, "./" <> path], output_limit: 4_096) do
      {:ok, %Execution{exit_status: 0, truncated: false, output: report}} -> {:ok, report}
      {:ok, %Execution{} = execution} -> {:error, execution}
      {:error, error} -> {:error, error}
    end
  end
end
