defmodule Jido.Workspace.Integration.Scenario01WorkspaceArtifactRoundtripTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 01 goal: Prove baseline artifact lifecycle works end to end in one integration scenario test.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :local_integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @error_path "/artifacts/errors.json"

  test "workspace artifact roundtrip persists summary artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("01_workspace_artifact_roundtrip", "spec-01", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      :ok = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      :ok = Workspace.write(workspace, "/artifacts/hello.txt", "Hello, World!")
      ScenarioHelpers.put_workspace(workspace)

      assert {:ok, "Hello, World!"} = Workspace.read(workspace, "/artifacts/hello.txt")

      assert {:ok, entries_before_delete} = Workspace.list(workspace, "/artifacts")
      assert Enum.any?(entries_before_delete, &(&1.path == "/artifacts/hello.txt"))

      :ok = Workspace.delete(workspace, "/artifacts/hello.txt")
      ScenarioHelpers.put_workspace(workspace)

      assert {:error, %Jido.Workspace.Error{code: :not_found}} =
               Workspace.read(workspace, "/artifacts/hello.txt")

      summary_json =
        ScenarioHelpers.summary_json(
          "01_workspace_artifact_roundtrip",
          "ok",
          workspace_id,
          [{"entries_before_delete", entries_before_delete}]
        )

      :ok = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      assert File.exists?(summary_file)
      assert {:ok, summary_contents} = File.read(summary_file)
      assert String.contains?(summary_contents, ~s("status": "ok"))
      assert String.contains?(summary_contents, workspace_id)
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end
end
