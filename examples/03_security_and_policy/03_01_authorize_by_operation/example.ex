defmodule Jido.Workspace.Examples.PublishReport do
  alias Jido.Workspace

  def publish(workspace, path) do
    with {:ok, report} <- Workspace.read(workspace, path),
         {:ok, snapshot} <- Workspace.save(workspace) do
      {:ok, %{report: report, snapshot: snapshot}}
    end
  end
end
