Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.DeploymentRecoveryTest do
  use ExUnit.Case, async: false

  alias Jido.Workspace
  alias Jido.Workspace.{Deploy, Sandbox}
  alias Jido.Workspace.Deploy.{Artifact, Recipe, Snapshot}
  alias Jido.Workspace.Examples.LifecycleSupport

  @moduletag :integration
  @moduletag :tmp_dir

  @verify_script ~S"""
  if [ "$(cat report.txt)" = "approved" ]; then
    printf 'verified\n'
  else
    printf 'candidate rejected\n' >&2
    exit 7
  fi
  """

  setup %{tmp_dir: root} do
    LifecycleSupport.configure(Path.join(root, "snapshots"))
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    reader = %{profiles.memory | policy: :read_only}
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, :reader, reader))
    :ok
  end

  test "inspect a failed deployment and recover a saved memory release on a local target" do
    verify_recovery(:memory, [])
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to test recovery with Docker"
  end

  test "inspect a failed deployment and recover a saved Docker release on a Docker target" do
    image = System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest")
    verify_recovery(:docker, provider: :docker, image: image)
  end

  test "a failed recovery holds the deployment gate and a new uncertain operation owns it" do
    {_, _, session} = target([])
    {ready, rejected} = save_versions(:memory)
    original = artifact(ready, "1")
    candidate = artifact(rejected, "2")
    recipe = %Recipe{verify: {"/bin/sh", ["verify.sh"]}}

    assert {:ok, plan} = Deploy.prepare(session, candidate, recipe: recipe)
    assert %{status: :recovery_required, id: failed} = run(session, plan)

    failed_prep = %{recipe | prepare: [{"/bin/sh", ["-c", "exit 9"]}]}
    assert {:ok, retry} = Deploy.recover(session, failed, original, recipe: failed_prep)
    assert %{status: :failed, evidence: %{phase: :prepare}} = run(session, retry)
    assert {:ok, %{controller: %{blocked_by: ^failed}}} = Deploy.inspect(session)

    assert {:ok, earlier_recovery} = Deploy.recover(session, failed, original, recipe: recipe)
    assert {:ok, retry} = Deploy.recover(session, failed, candidate, recipe: recipe)

    assert %{status: :recovery_required, id: new_failure, recovery_of: ^failed} =
             run(session, retry)

    assert {:ok, %{controller: %{blocked_by: ^new_failure}}} = Deploy.inspect(session)
    assert {:error, :recovery_required} = Deploy.apply(session, earlier_recovery)

    assert {:error, :recovery_required} =
             Deploy.recover(session, failed, original, recipe: recipe)

    assert {:ok, retry} = Deploy.recover(session, new_failure, original, recipe: recipe)
    assert %{status: :succeeded, recovery_of: ^new_failure} = run(session, retry)
    assert {:ok, %{controller: %{blocked: false, blocked_by: nil}}} = Deploy.inspect(session)
  end

  defp verify_recovery(profile, target_opts) do
    {sandbox, target, session} = target(target_opts)
    {ready, rejected} = save_versions(profile)
    original = artifact(ready, "1")
    candidate = artifact(rejected, "2")

    recipe = %Recipe{
      service: %{executable: "/bin/sleep", args: ["120"]},
      verify: {"/bin/sh", ["verify.sh"]}
    }

    assert {:ok, plan} = Deploy.prepare(session, original, recipe: recipe)

    assert %{
             id: verified,
             status: :succeeded,
             evidence: %{service: first_service, current: first_release}
           } = run(session, plan)

    assert {:ok, stale_recovery} = Deploy.recover(session, verified, original, recipe: recipe)
    assert {:ok, plan} = Deploy.prepare(session, candidate, recipe: recipe)

    assert %{
             id: failed,
             snapshot_id: ^rejected,
             status: :recovery_required,
             before: %{current: ^first_release},
             after: {:ok, %{identity: %{current: failed_release, service: failed_service}}},
             evidence: %{phase: :verify, reason: reason},
             steps: steps
           } = run(session, plan)

    assert {:error,
            {:command_failed, %{executable: "/bin/sh", args: ["verify.sh"]},
             {:ok, %{exit_status: 7, output: "candidate rejected\n"}}}} = reason

    assert %{phase: :verify, evidence: ^reason} = List.last(steps)
    assert {:ok, %{status: :stopped}} = Sandbox.service_status(sandbox, first_service)

    assert {:ok,
            %{
              controller: %{blocked: true, blocked_by: ^failed},
              identity: %{current: ^failed_release, service: ^failed_service},
              runtime: {:ok, %{status: :running}}
            }} = Deploy.inspect(session)

    assert {:ok, "rejected\n"} =
             Sandbox.read(sandbox, Path.join([target.path, failed_release, "report.txt"]))

    assert {:ok, ordinary} = Deploy.prepare(session, original, recipe: recipe)
    assert {:error, :recovery_required} = Deploy.apply(session, ordinary)
    assert {:error, :recovery_required} = Deploy.apply(session, stale_recovery)
    assert {:error, :unknown_or_changed_plan} = Deploy.apply(session, plan.id)

    assert {:error, :invalid_artifact_or_target_kind} =
             Deploy.recover(session, failed, original, %{})

    assert {:error, :recovery_verification_required} = Deploy.recover(session, failed, original)

    restored_artifact = artifact(Jason.decode!(Jason.encode!(ready)), "1")
    assert {:ok, recovery} = Deploy.recover(session, failed, restored_artifact, recipe: recipe)

    assert %{
             status: :succeeded,
             recovery_of: ^failed,
             snapshot_id: ^ready,
             evidence: %{
               current: restored_release,
               service: restored_service,
               state_policy: :restart,
               verification: [%{exit_status: 0, output: "verified\n"}]
             }
           } = run(session, recovery)

    assert restored_release != first_release
    assert {:ok, %{status: :stopped}} = Sandbox.service_status(sandbox, failed_service)

    assert {:ok,
            %{
              controller: %{blocked: false, blocked_by: nil},
              identity: %{current: ^restored_release, service: ^restored_service},
              runtime: {:ok, %{status: :running}}
            }} = Deploy.inspect(session)

    assert :ok =
             Snapshot.verify(
               restored_artifact.snapshot,
               Path.join([sandbox.root, target.path, restored_release])
             )

    assert {:ok, %{status: :recovery_required}} = Deploy.status(session, failed)
  end

  defp save_versions(profile) do
    assert {:ok, workspace} = Workspace.open(profile: profile)

    try do
      assert :ok = Workspace.write(workspace, "verify.sh", @verify_script)
      assert :ok = Workspace.write(workspace, "report.txt", "approved\n")
      assert {:ok, ready} = Workspace.save(workspace)
      assert :ok = Workspace.write(workspace, "report.txt", "rejected\n")
      assert {:ok, rejected} = Workspace.save(workspace)
      {ready, rejected}
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp artifact(reference, version) do
    assert {:ok, payload} = Snapshot.from_saved(reference, profile: :reader)
    assert {:ok, artifact} = Artifact.new(:source, version, payload)
    artifact
  end

  defp target(opts) do
    assert {:ok, sandbox} = Sandbox.open(Keyword.put(opts, :owner, self()))
    assert {:ok, target} = Deploy.source_target(sandbox, "report")
    assert {:ok, session} = Deploy.connect(target)
    {sandbox, target, session}
  end

  defp run(session, plan) do
    assert {:ok, id} = Deploy.apply(session, plan)
    assert {:ok, record} = Deploy.await(session, id)
    record
  end
end
