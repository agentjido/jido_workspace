Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.ReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Jido.Workspace
  alias Jido.Workspace.Examples.Report

  test "file calls and virtual tools see the same memory tree" do
    previous = Application.fetch_env(:jido_workspace, :profiles)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_workspace, :profiles, value)
        :error -> Application.delete_env(:jido_workspace, :profiles)
      end
    end)

    Application.put_env(:jido_workspace, :profiles, %{
      memory: %{provider: :memory, policy: :full_access}
    })

    input = "Report for today\n"
    assert {:ok, workspace} = Workspace.open(profile: :memory)

    try do
      assert {:ok, ^input} = Report.run(workspace, input)
    after
      assert :ok = Workspace.close(workspace)
    end

    assert {:error, %Workspace.Error{code: :closed}} =
             Workspace.read(workspace, "reports/output data.txt")
  end
end
