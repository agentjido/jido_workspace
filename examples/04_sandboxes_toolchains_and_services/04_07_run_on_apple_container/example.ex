defmodule Jido.Workspace.Examples.AppleContainer do
  @moduledoc "Copy a report with literal arguments and save the workspace tree."

  alias Jido.Workspace

  def copy_and_save(workspace, report) do
    directory = "reports today"
    source = "draft $notes.txt"
    destination = "reviewed report.txt"

    with :ok <- Workspace.mkdir(workspace, directory),
         :ok <- Workspace.write(workspace, Path.join(directory, source), report),
         {:ok, %{status: :exited, exit_status: 0}} <-
           Workspace.run(workspace, ["/bin/cp", source, destination], cwd: directory) do
      Workspace.save(workspace)
    else
      {:ok, execution} -> {:error, execution}
      {:error, _} = error -> error
    end
  end
end
