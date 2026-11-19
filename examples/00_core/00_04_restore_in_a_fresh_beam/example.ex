defmodule Jido.Workspace.Examples.PersistedReport do
  @moduledoc "Save a report and use the durable reference to reopen its tree."

  alias Jido.Workspace

  def export(profile, report) do
    with {:ok, workspace} <- Workspace.open(profile: profile) do
      try do
        with :ok <- Workspace.mkdir(workspace, "empty"),
             :ok <- Workspace.write(workspace, "report", report) do
          Workspace.save(workspace)
        end
      after
        Workspace.close(workspace)
      end
    end
  end

  def restore(profile, snapshot) do
    with {:ok, workspace} <- Workspace.open(profile: profile, from: snapshot) do
      try do
        with {:ok, report} <- Workspace.read(workspace, "report"),
             {:ok, empty_entries} <- Workspace.list(workspace, "empty") do
          {:ok, %{report: report, empty_entries: empty_entries}}
        end
      after
        Workspace.close(workspace)
      end
    end
  end
end
