defmodule Jido.Workspace.Examples.ReadReports do
  @moduledoc "Read reports in one directory and keep output from a failed read."

  alias Jido.Workspace
  alias Jido.Workspace.Execution

  def read(workspace, directory, names, output_limit) do
    case Workspace.run(workspace, ["cat" | names], cwd: directory, output_limit: output_limit) do
      {:ok, %Execution{status: :exited, exit_status: 0} = execution} ->
        {:ok, execution}

      {:ok, execution} ->
        {:incomplete, execution}

      {:error, _} = error ->
        error
    end
  end
end
