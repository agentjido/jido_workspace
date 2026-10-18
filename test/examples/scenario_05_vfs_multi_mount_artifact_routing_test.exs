defmodule Jido.Workspace.Integration.Scenario05VFSMultiMountArtifactRoutingTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 05 goal: Mount multiple filesystems and prove path routing works correctly.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :local_integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @mounts_path "/artifacts/mounts.json"
  @error_path "/artifacts/errors.json"

  test "multi-mount routing isolates scratch and repo paths", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!(
        "05_vfs_multi_mount_artifact_routing",
        "spec-05",
        tmp_dir
      )

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    repo_mount_prefix = Path.join(output_root, "repo_mount")
    :ok = File.mkdir_p!(repo_mount_prefix)

    scratch_name = "spec05_scratch_#{System.unique_integer([:positive])}"

    try do
      :ok =
        Jido.Shell.VFS.mount(workspace_id, "/scratch", Jido.VFS.Adapter.InMemory,
          name: scratch_name
        )

      :ok =
        Jido.Shell.VFS.mount(workspace_id, "/repo", Jido.VFS.Adapter.Local,
          prefix: repo_mount_prefix
        )

      assert :ok = Jido.Shell.VFS.write_file(workspace_id, "/scratch/scratch.txt", "scratch-data")
      assert :ok = Jido.Shell.VFS.write_file(workspace_id, "/repo/repo.txt", "repo-data")

      assert {:ok, "scratch-data"} =
               Jido.Shell.VFS.read_file(workspace_id, "/scratch/scratch.txt")

      assert {:ok, "repo-data"} = Jido.Shell.VFS.read_file(workspace_id, "/repo/repo.txt")

      assert :ok = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      mounts =
        Jido.Shell.VFS.list_mounts(workspace_id)
        |> Enum.map(& &1.path)
        |> Enum.sort()

      assert "/" in mounts
      assert "/repo" in mounts
      assert "/scratch" in mounts

      repo_file = Path.join(repo_mount_prefix, "repo.txt")
      root_scratch_file = Path.join(output_root, "scratch/scratch.txt")

      assert File.exists?(repo_file)
      refute File.exists?(root_scratch_file)

      mounts_json =
        ScenarioHelpers.summary_json(
          "05_vfs_multi_mount_artifact_routing",
          "ok",
          workspace_id,
          [
            {"mount_paths", mounts},
            {"repo_mount_prefix", repo_mount_prefix},
            {"repo_file_exists", true},
            {"scratch_routed_away_from_root", true}
          ]
        )

      :ok = Workspace.write(workspace, @mounts_path, mounts_json)
      :ok = Workspace.write(workspace, @summary_path, mounts_json)
      ScenarioHelpers.put_workspace(workspace)

      mounts_file = Path.join(output_root, "artifacts/mounts.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(mounts_file)
      assert File.exists?(summary_file)

      assert {:ok, mount_contents} = File.read(mounts_file)
      assert String.contains?(mount_contents, "mount_paths")
      assert String.contains?(mount_contents, "/repo")
      assert String.contains?(mount_contents, "/scratch")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end
end
