defmodule Jido.Workspace.Examples.RestrictedReport do
  @moduledoc "Observe what a read-only caller can do through Workspace and Sandbox."

  alias Jido.Workspace
  alias Jido.Workspace.Sandbox

  def workspace(workspace) do
    %{
      read: Workspace.read(workspace, "/report.txt"),
      write: Workspace.write(workspace, "/report.txt", "Changed"),
      run: Workspace.run(workspace, "cat /report.txt")
    }
  end

  def sandbox(sandbox) do
    %{
      read: Sandbox.read(sandbox, "report.txt"),
      write: Sandbox.write(sandbox, "report.txt", "Changed"),
      run: Sandbox.exec(sandbox, "/bin/cat", ["report.txt"])
    }
  end
end
