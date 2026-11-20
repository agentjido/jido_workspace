defmodule Jido.Workspace.Examples.RootedReport do
  alias Jido.Workspace

  def read_with_tool(workspace, path) do
    with {:ok, report} <- Workspace.read(workspace, path),
         file = "./" <> Path.basename(path),
         {:ok, execution} <-
           Workspace.run(workspace, ["cat", file], cwd: Path.dirname(path)) do
      {:ok, %{report: report, execution: execution}}
    end
  end
end
