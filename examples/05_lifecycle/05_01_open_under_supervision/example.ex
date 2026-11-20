defmodule Jido.Workspace.Examples.OwnedReport do
  @moduledoc "Place a workspace under a host-owned process and save a recovery point."

  alias Jido.Workspace

  def prepare(profile, owner, report) do
    with {:ok, workspace} <- Workspace.open(profile: profile, owner: owner) do
      case save_report(workspace, report) do
        {:ok, snapshot} ->
          {:ok, workspace, snapshot}

        {:error, _} = error ->
          with :ok <- Workspace.close(workspace), do: error
      end
    end
  end

  defp save_report(workspace, report) do
    with :ok <- Workspace.write(workspace, "report.txt", report), do: Workspace.save(workspace)
  end
end
