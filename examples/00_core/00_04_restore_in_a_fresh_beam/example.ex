defmodule Jido.Workspace.Examples.PersistedReport do
  @moduledoc "Save a report and reopen its tree from a reference stored as JSON."

  alias Jido.Workspace

  def export(profile, report, reference_path) do
    with {:ok, workspace} <- Workspace.open(profile: profile) do
      try do
        with :ok <- Workspace.mkdir(workspace, "empty"),
             :ok <- Workspace.write(workspace, "report.txt", report),
             {:ok, snapshot} <- Workspace.save(workspace),
             {:ok, json} <- Jason.encode(snapshot),
             :ok <- File.write(reference_path, json) do
          {:ok, snapshot}
        end
      after
        Workspace.close(workspace)
      end
    end
  end

  def restore(profile, reference_path) do
    with {:ok, json} <- File.read(reference_path),
         {:ok, snapshot} <- Jason.decode(json),
         {:ok, workspace} <- Workspace.open(profile: profile, from: snapshot) do
      try do
        with {:ok, report} <- Workspace.read(workspace, "report.txt"),
             {:ok, empty_entries} <- Workspace.list(workspace, "empty") do
          {:ok, %{report: report, empty_entries: empty_entries}}
        end
      after
        Workspace.close(workspace)
      end
    end
  end
end
