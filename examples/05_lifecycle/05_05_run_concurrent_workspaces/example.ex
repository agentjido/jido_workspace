defmodule Jido.Workspace.Examples.ConcurrentReports do
  @moduledoc "Read a report in a caller task while the host retains workspace ownership."

  alias Jido.Workspace

  def read(workspace, opts \\ []) do
    Task.async(fn -> Workspace.run(workspace, ["cat", "report.txt"], opts) end)
  end
end
