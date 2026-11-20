defmodule Jido.Workspace.Examples.FindProjectFiles do
  alias Jido.Workspace

  def inspect_first_match(workspace, directory, marker) do
    with {:ok, [entry | _]} <- Workspace.find(workspace, directory, contains: marker),
         {:ok, bytes, revision} <- Workspace.read(workspace, entry.path, revision: true) do
      {:ok, %{entry: entry, bytes: bytes, revision: revision}}
    else
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end
end
