defmodule Jido.Workspace.Deploy.OTPReleaseTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 120_000
  alias Jido.Workspace.Deploy
  alias Jido.Workspace.Deploy.OTP
  alias Jido.Workspace.Sandbox

  test "real appup and relup preserve live state and support an explicit downgrade" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    artifacts = Jido.Workspace.Deploy.Test.Releases.build(Path.join(sandbox.root, "build"))
    assert {:ok, target} = OTP.start(sandbox, "counter", artifacts["1"])
    assert {:ok, session} = Deploy.connect(target)

    assert {:ok, {pid, ~c"1", %{count: 10, requests: 0}}} =
             OTP.call(target, :counter_server, :inspect, [])

    assert {:ok, %{count: 13, requests: 1}} = OTP.call(target, :counter_server, :add, [3])

    assert {:ok, plan} =
             Deploy.prepare(session, artifacts["2"],
               preflight: {:counter_server, :preflight, [true]},
               verify: {:counter_server, :preflight, [true]}
             )

    {:ok, stale} = Deploy.prepare(session, artifacts["2"])

    # Traffic after planning must remain part of the migration input.
    assert {:ok, %{count: 17, requests: 2}} = OTP.call(target, :counter_server, :add, [4])
    assert {:ok, id} = Deploy.apply(session, plan)
    assert {:ok, %{status: :succeeded} = record} = Deploy.await(session, id)
    assert record.snapshot_id == "counter-source-2"

    assert {:ok, {^pid, ~c"2", %{total: 17, requests: 2}}} =
             OTP.call(target, :counter_server, :inspect, [])

    assert {:ok, %{total: 27, requests: 3}} = OTP.call(target, :counter_server, :add, [5])
    assert {:ok, ^id} = Deploy.apply(session, plan)
    assert {:error, :unknown_or_changed_plan} = Deploy.apply(session, %{plan | expected: %{}})
    {:ok, stale_id} = Deploy.apply(session, stale)

    assert {:ok, %{status: :failed, evidence: :stale_target_or_payload}} =
             Deploy.await(session, stale_id)

    assert :ok = Sandbox.close(sandbox)
    assert {:ok, attached} = Sandbox.attach(sandbox.id)
    assert attached.pid == sandbox.pid

    assert {:ok, recovery} = Deploy.recover(session, id, artifacts["1"])
    assert {:ok, recovery_id} = Deploy.apply(session, recovery)
    assert {:ok, %{status: :succeeded}} = Deploy.await(session, recovery_id)

    assert {:ok, {^pid, ~c"1", %{count: 27, requests: 3}}} =
             OTP.call(target, :counter_server, :inspect, [])
  end

  test "failed behavior verification blocks deployment until explicit recovery" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    artifacts = Jido.Workspace.Deploy.Test.Releases.build(Path.join(sandbox.root, "build"))
    {:ok, target} = OTP.start(sandbox, "counter", artifacts["1"])
    {:ok, session} = Deploy.connect(target)

    {:ok, plan} =
      Deploy.prepare(session, artifacts["2"], verify: {:counter_server, :preflight, [false]})

    {:ok, id} = Deploy.apply(session, plan)
    assert {:ok, %{status: :recovery_required}} = Deploy.await(session, id)
    assert {:ok, %{identity: %{release: ~c"2"}}} = Deploy.inspect(session)
    {:ok, ordinary} = Deploy.prepare(session, artifacts["1"])
    assert {:error, :recovery_required} = Deploy.apply(session, ordinary)
    {:ok, recovery} = Deploy.recover(session, id, artifacts["1"])
    {:ok, recovery_id} = Deploy.apply(session, recovery)
    assert {:ok, %{status: :succeeded}} = Deploy.await(session, recovery_id)
  end

  test "a refused migration guard leaves the release, state, and PID unchanged" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    artifacts = Jido.Workspace.Deploy.Test.Releases.build(Path.join(sandbox.root, "build"))
    {:ok, target} = OTP.start(sandbox, "counter", artifacts["1"])
    {:ok, session} = Deploy.connect(target)
    {:ok, before} = OTP.call(target, :counter_server, :inspect, [])

    {:ok, plan} =
      Deploy.prepare(session, artifacts["2"], preflight: {:counter_server, :preflight, [false]})

    {:ok, id} = Deploy.apply(session, plan)
    assert {:ok, %{status: :failed}} = Deploy.await(session, id)
    assert {:ok, ^before} = OTP.call(target, :counter_server, :inspect, [])
    assert {:ok, %{identity: %{release: ~c"1"}}} = Deploy.inspect(session)
  end
end
