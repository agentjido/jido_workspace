defmodule Jido.Workspace.Examples.RestrictedReport do
  @moduledoc "Observe which operations a read-only Workspace permits."

  alias Jido.Workspace

  def check(workspace) do
    %{
      read: Workspace.read(workspace, "report.txt"),
      write: Workspace.write(workspace, "report.txt", "Changed"),
      run: Workspace.run(workspace, ["cat", "report.txt"])
    }
  end
end
