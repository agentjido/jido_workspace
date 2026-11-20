Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.OTPUpgradeTest do
  use ExUnit.Case, async: false

  alias Jido.Workspace
  alias Jido.Workspace.{Deploy, Sandbox}
  alias Jido.Workspace.Deploy.{Artifact, OTP, Snapshot}
  alias Jido.Workspace.Deploy.Test.Releases
  alias Jido.Workspace.Examples.LifecycleSupport
  alias Jido.Workspace.TestSupport.TargetCoverage

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  setup %{tmp_dir: root} do
    LifecycleSupport.configure(Path.join(root, "snapshots"))
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    reader = %{profiles.memory | policy: :read_only}
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, :reader, reader))
    %{fixtures: Releases.build(Path.join(root, "build"))}
  end

  test "saved releases preserve state on live transitions and reset it on a failed migration", %{
    fixtures: fixtures
  } do
    saved =
      Map.new(fixtures, fn {version, fixture} -> {version, save_release(:memory, fixture)} end)

    initial = artifact(saved["1"], "1")
    sandbox = sandbox([])
    assert {:ok, target} = OTP.start(sandbox, "counter", initial)
    TargetCoverage.start(target)
    assert {:ok, session} = Deploy.connect(target)
    assert {:ok, %{identity: %{generation: generation}}} = Deploy.inspect(session)
    assert {:ok, {pid, ~c"1", %{count: 10, requests: 0}}} = counter(target, :inspect)
    assert {:ok, %{count: 13, requests: 1}} = counter(target, :add, [3])

    upgrade = artifact(saved["2"], "2")
    check = {:counter_server, :preflight, [true]}
    assert {:ok, plan} = Deploy.prepare(session, upgrade, preflight: check, verify: check)

    # This synchronous call completes after planning and before installation.
    assert {:ok, %{count: 17, requests: 2}} = counter(target, :add, [4])

    assert %{
             status: :succeeded,
             id: upgrade_id,
             snapshot_id: selected,
             after: {:ok, %{identity: %{generation: ^generation, release: ~c"2"}}}
           } = run(session, plan)

    assert selected == saved["2"]
    assert {:ok, {^pid, ~c"2", %{total: 17, requests: 2}}} = counter(target, :inspect)
    assert {:ok, %{total: 27, requests: 3}} = counter(target, :add, [5])

    assert {:ok, downgrade} = Deploy.recover(session, upgrade_id, initial)
    assert %{status: :succeeded, recovery_of: ^upgrade_id} = run(session, downgrade)
    assert {:ok, {^pid, ~c"1", %{count: 27, requests: 3}}} = counter(target, :inspect)

    broken = artifact(saved["3"], "3")
    assert {:ok, plan} = Deploy.prepare(session, broken)
    assert :ok = TargetCoverage.export(target)
    assert %{status: :recovery_required, id: failed_id} = run(session, plan)

    wait_for_restart(target, generation)
    TargetCoverage.start(target)

    assert {:ok, %{controller: %{blocked_by: ^failed_id}, identity: %{release: ~c"1"}}} =
             Deploy.inspect(session)

    assert {:ok, {restarted_pid, ~c"1", %{count: 10, requests: 0}}} = counter(target, :inspect)
    refute restarted_pid == pid
    assert {:ok, ordinary} = Deploy.prepare(session, upgrade)
    assert {:error, :recovery_required} = Deploy.apply(session, ordinary)

    assert {:ok, recovery} = Deploy.recover(session, failed_id, upgrade, verify: check)
    assert %{status: :succeeded, recovery_of: ^failed_id} = run(session, recovery)
    assert {:ok, {^restarted_pid, ~c"2", %{total: 10, requests: 0}}} = counter(target, :inspect)
    assert {:ok, %{controller: %{blocked_by: nil}}} = Deploy.inspect(session)
  end

  test "an existing file with the wrong executable mode blocks registration", %{
    fixtures: fixtures
  } do
    sandbox = sandbox([])
    assert {:ok, target} = OTP.start(sandbox, "counter", fixtures["1"])
    TargetCoverage.start(target)
    assert {:ok, session} = Deploy.connect(target)
    assert {:ok, before} = Deploy.inspect(session)

    next = fixtures["2"]
    path = "lib/counter_demo-2/ebin/counter_server.beam"
    %{bytes: bytes, mode: 0o644} = next.snapshot.entries[path]
    target_path = Path.join(target.path, path)
    assert :ok = Sandbox.write(sandbox, target_path, bytes, 0o755)
    assert {:ok, plan} = Deploy.prepare(session, next)

    assert %{status: :failed, evidence: {:stage_failed, {:error, {:source_changed, ^path}}}} =
             run(session, plan)

    assert {:ok, ^before} = Deploy.inspect(session)
    assert :ok = Sandbox.write(sandbox, target_path, bytes, 0o644)
    assert {:ok, retry} = Deploy.prepare(session, next)
    assert %{status: :succeeded} = run(session, retry)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to test the Docker source and target capability"
  end

  test "a Docker workspace saves a release and a Docker target refuses OTP before copying", %{
    fixtures: fixtures
  } do
    release = artifact(save_release(:docker, fixtures["1"]), "1")
    image = System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest")
    docker = sandbox(provider: :docker, image: image)
    assert %{beam_call: false} = Sandbox.capabilities(docker)
    assert {:error, {:unsupported_capability, :beam_call}} = OTP.start(docker, "counter", release)
    assert {:error, :enoent} = Sandbox.read(docker, "counter/releases/1/counter.rel")
    refute File.exists?(Path.join(docker.root, "counter"))

    local = sandbox([])
    assert {:ok, target} = OTP.start(local, "counter", release)
    TargetCoverage.start(target)
    assert {:ok, {_, ~c"1", %{count: 10, requests: 0}}} = counter(target, :inspect)
  end

  defp save_release(profile, artifact) do
    assert {:ok, workspace} = Workspace.open(profile: profile)

    try do
      for {path, %{bytes: bytes}} <- artifact.snapshot.entries do
        assert :ok = Workspace.write(workspace, path, bytes)
      end

      assert {:ok, reference} = Workspace.save(workspace)
      reference
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp artifact(reference, version) do
    assert {:ok, payload} = Snapshot.from_saved(reference, profile: :reader)
    assert {:ok, artifact} = Artifact.new(:otp, version, payload)
    artifact
  end

  defp sandbox(opts) do
    assert {:ok, sandbox} = Sandbox.open(opts)
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    sandbox
  end

  defp counter(target, fun, args \\ []), do: OTP.call(target, :counter_server, fun, args)

  defp run(session, plan) do
    assert {:ok, id} = Deploy.apply(session, plan)
    assert {:ok, record} = Deploy.await(session, id)
    record
  end

  defp wait_for_restart(target, old_generation) do
    LifecycleSupport.await(
      fn ->
        with {:ok, ^target} <- OTP.reconnect(target),
             {:ok, %{identity: %{generation: generation}}} <- OTP.inspect(target) do
          generation != old_generation
        else
          _ -> false
        end
      end,
      "OTP did not restart with a new control generation",
      10_000
    )
  end
end
