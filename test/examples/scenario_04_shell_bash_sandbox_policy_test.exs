defmodule Jido.Workspace.Integration.Scenario04ShellBashSandboxPolicyTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 04 goal: Verify bash sandbox network limits and allowlist behavior using execution_context.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :local_integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @matrix_path "/artifacts/network_policy.json"
  @error_path "/artifacts/errors.json"
  @command ~s(bash -c "curl https://example.com")

  test "bash sandbox blocks network by default and allows policy override", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("04_shell_bash_sandbox_policy", "spec-04", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      :ok = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      {deny_error, workspace} = run_expect_error(workspace, @command)
      assert :policy_denied = deny_error.code
      assert deny_error.details.cause == "{:shell, :network_blocked}"

      {allow_error, workspace} =
        run_expect_error(
          workspace,
          @command,
          execution_context: %{network: %{allow_domains: ["example.com"]}}
        )

      # When allowlisted, network policy passes and bash then fails at command lookup in the sandbox.
      assert :start_failed = allow_error.code
      assert allow_error.details.cause == "{:shell, :unknown_command}"

      :ok = Workspace.stop_session(workspace)
      ScenarioHelpers.put_workspace(workspace)

      matrix_json =
        ScenarioHelpers.summary_json(
          "04_shell_bash_sandbox_policy",
          "ok",
          workspace_id,
          [
            {"command", @command},
            {"default_policy_error", deny_error.details.cause},
            {"allowlist_policy_error", allow_error.details.cause},
            {"blocked_by_default", true},
            {"allowlist_reached_command_execution", true}
          ]
        )

      :ok = Workspace.write(workspace, @matrix_path, matrix_json)
      :ok = Workspace.write(workspace, @summary_path, matrix_json)
      ScenarioHelpers.put_workspace(workspace)

      matrix_file = Path.join(output_root, "artifacts/network_policy.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(matrix_file)
      assert File.exists?(summary_file)

      assert {:ok, matrix_contents} = File.read(matrix_file)
      assert String.contains?(matrix_contents, "network_blocked")
      assert String.contains?(matrix_contents, "unknown_command")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_expect_error(workspace, command, opts \\ []) do
    case Workspace.run(workspace, command, opts) do
      {:error, %Jido.Workspace.Error{} = error} ->
        {error, workspace}

      {:ok, %{output: output}} ->
        flunk(
          "expected error running #{inspect(command)}, got output #{inspect(output)} in workspace #{workspace.id}"
        )

      other ->
        flunk("unexpected command result: #{inspect(other)}")
    end
  end
end
