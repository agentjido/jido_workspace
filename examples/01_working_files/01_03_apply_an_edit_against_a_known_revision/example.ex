defmodule Jido.Workspace.Examples.EditKnownRevision do
  alias Jido.Workspace

  def edit(workspace, path, revise) do
    with {:ok, bytes, revision} <- Workspace.read(workspace, path, revision: true) do
      Workspace.write(workspace, path, revise.(bytes), expected: revision)
    end
  end
end
