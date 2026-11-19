Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.MemoryReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Jido.Workspace
  alias Jido.Workspace.Examples.MemoryReport

  test "virtual commands share working files and the fixed capture survives close" do
    input = "Report for today\n"

    assert {:ok, %{output: ^input, capture: capture, closed_workspace: closed}} =
             MemoryReport.run(input)

    assert {:error, %Workspace.Error{code: :closed}} =
             Workspace.write(closed, "/reports/output.txt", "Refused")

    assert {:ok, ^input} = MemoryReport.captured_output(capture)
    assert {:ok, ^input} = MemoryReport.reopen(capture)
  end
end
