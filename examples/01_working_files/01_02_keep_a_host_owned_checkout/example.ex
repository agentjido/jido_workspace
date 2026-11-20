defmodule Jido.Workspace.Examples.EditCheckout do
  alias Jido.Workspace

  def revise_draft(workspace, text) do
    with :ok <- Workspace.write(workspace, "draft.txt", text) do
      Workspace.run(workspace, ["cat", "draft.txt"])
    end
  end
end
