defmodule Jido.Workspace.Examples.MemoryReport do
  @moduledoc "Create a report with virtual tools and inspect a fixed capture."

  alias Jido.{VFS, Workspace}

  def run(input) do
    with {:ok, workspace} <- Workspace.open(policy: :full_access) do
      try do
        with :ok <- Workspace.mkdir(workspace, "/reports"),
             :ok <- Workspace.write(workspace, "/reports/input.txt", input),
             {:ok, %{exit_status: 0}} <-
               Workspace.run(workspace, "cp /reports/input.txt /reports/output.txt"),
             {:ok, output} <- Workspace.read(workspace, "/reports/output.txt"),
             {:ok, capture, _revision} <- Workspace.capture(workspace),
             :ok <- Workspace.write(workspace, "/reports/output.txt", "Later edit\n") do
          {:ok, %{output: output, capture: capture, closed_workspace: workspace}}
        else
          {:ok, %Workspace.Execution{} = execution} -> {:error, execution}
          error -> error
        end
      after
        Workspace.close(workspace)
      end
    end
  end

  def reopen(capture) do
    with {:ok, workspace} <- Workspace.open() do
      try do
        with {:ok, _empty, revision} <- Workspace.capture(workspace),
             {:ok, _revision} <- Workspace.replace(workspace, capture, expected: revision) do
          Workspace.read(workspace, "/reports/output.txt")
        end
      after
        Workspace.close(workspace)
      end
    end
  end

  def captured_output(capture), do: VFS.read(capture, "reports/output.txt")
end
