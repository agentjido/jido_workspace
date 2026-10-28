defmodule Jido.Workspace.Integration.Scenario02WorkspaceShellPwdWriteTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 02 goal: Validate shell command execution and artifact changes in the same workspace.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :local_integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @error_path "/artifacts/errors.json"

  test "workspace shell pwd/write/cat loop persists command artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("02_workspace_shell_pwd_write", "spec-02", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      :ok = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      {:ok, %{output: pwd_output}} = Workspace.run(workspace, "pwd")
      ScenarioHelpers.put_workspace(workspace)

      :ok = Workspace.write(workspace, "/artifacts/pwd_output.txt", pwd_output)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, %{output: write_output}} =
        Workspace.run(workspace, "write /artifacts/from_shell.txt hello")

      ScenarioHelpers.put_workspace(workspace)
      assert String.contains?(write_output, "wrote")

      {:ok, %{output: cat_output}} = Workspace.run(workspace, "cat /artifacts/from_shell.txt")
      ScenarioHelpers.put_workspace(workspace)
      assert String.trim(cat_output) == "hello"

      assert {:ok, "hello"} = Workspace.read(workspace, "/artifacts/from_shell.txt")

      transcript =
        [
          "$ pwd",
          String.trim(pwd_output),
          "",
          "$ write /artifacts/from_shell.txt hello",
          String.trim(write_output),
          "",
          "$ cat /artifacts/from_shell.txt",
          String.trim(cat_output)
        ]
        |> Enum.join("\n")

      :ok =
        Workspace.write(workspace, "/artifacts/command_transcript.txt", transcript)

      ScenarioHelpers.put_workspace(workspace)

      :ok = Workspace.stop_session(workspace)
      ScenarioHelpers.put_workspace(workspace)

      summary_json =
        ScenarioHelpers.summary_json(
          "02_workspace_shell_pwd_write",
          "ok",
          workspace_id,
          [
            {"pwd", String.trim(pwd_output)},
            {"shell_file", "/artifacts/from_shell.txt"},
            {"transcript_file", "/artifacts/command_transcript.txt"}
          ]
        )

      :ok = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      transcript_file = Path.join(output_root, "artifacts/command_transcript.txt")

      assert File.exists?(summary_file)
      assert File.exists?(transcript_file)

      assert {:ok, transcript_contents} = File.read(transcript_file)
      assert String.contains?(transcript_contents, "$ pwd")
      assert String.contains?(transcript_contents, "$ cat /artifacts/from_shell.txt")
      assert String.contains?(transcript_contents, "hello")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end
end
