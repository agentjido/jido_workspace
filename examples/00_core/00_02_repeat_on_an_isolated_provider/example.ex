defmodule Jido.Workspace.Examples.ProfiledReport do
  @moduledoc "Run the same report with a host-selected provider profile."

  alias Jido.Workspace
  alias Jido.Workspace.Examples.Report

  def run(profile, input) do
    with {:ok, workspace} <- Workspace.open(profile: profile) do
      try do
        Report.run(workspace, input)
      after
        Workspace.close(workspace)
      end
    end
  end
end
