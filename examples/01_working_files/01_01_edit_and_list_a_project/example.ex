defmodule Jido.Workspace.Examples.EditProject do
  @moduledoc "Prepare a project and move a draft into review."

  alias Jido.Workspace

  def prepare_review(workspace, draft) do
    with :ok <- Workspace.mkdir(workspace, "project/inbox"),
         :ok <- Workspace.mkdir(workspace, "project/review"),
         :ok <- Workspace.write(workspace, "project/inbox/draft.txt", draft),
         :ok <- Workspace.move(workspace, "project/inbox/draft.txt", "project/review/draft.txt"),
         :ok <- Workspace.delete(workspace, "project/inbox"),
         {:ok, draft} <- Workspace.read(workspace, "project/review/draft.txt"),
         {:ok, entries} <- Workspace.list(workspace, "project/review") do
      {:ok, draft, entries}
    end
  end
end
