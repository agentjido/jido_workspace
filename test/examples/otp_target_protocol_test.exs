defmodule Jido.Workspace.Deploy.OTPTargetProtocolTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 120_000

  alias Jido.Workspace.Deploy.OTP
  alias Jido.Workspace.Sandbox
  alias Jido.Workspace.TestSupport.TargetCoverage

  setup do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    artifacts = Jido.Workspace.Deploy.Test.Releases.build(Path.join(sandbox.root, "build"))
    {:ok, target} = OTP.start(sandbox, "counter", artifacts["1"])
    TargetCoverage.start(target)
    %{target: target}
  end

  test "control messages preserve identity and a server restart changes its generation", %{
    target: target
  } do
    assert {:ok, before} = OTP.inspect(target)
    assert {:ok, :ok} = call(target, :start, [])
    assert {:ok, :error} = call(target, :status, ["missing"])

    assert {:ok, {:error, :unsupported}} =
             OTP.call(target, :gen_server, :call, [:jido_workspace_deploy_target, :unknown])

    assert {:ok, :ok} =
             OTP.call(target, :gen_server, :cast, [:jido_workspace_deploy_target, :unknown])

    assert {:ok, :unknown} =
             OTP.call(target, :erlang, :send, [:jido_workspace_deploy_target, :unknown])

    assert {:ok, ^before} = OTP.inspect(target)
    assert {:ok, :ok} = OTP.call(target, :gen_server, :stop, [:jido_workspace_deploy_target])
    assert {:ok, :ok} = call(target, :start, [])
    assert {:ok, after_restart} = OTP.inspect(target)
    assert after_restart.identity.release == before.identity.release
    refute after_restart.identity.generation == before.identity.generation
  end

  test "stale identity and an unknown release are refused without changing the release", %{
    target: target
  } do
    {:ok, before} = OTP.inspect(target)

    assert {:ok, {:error, :stale_target}} =
             call(target, :install, ["stale", %{}, ~c"missing", nil, false])

    for guard <- [nil, :undefined] do
      id = inspect(guard)

      assert {:ok, {:ok, ^id}} =
               call(target, :install, [id, before.identity, ~c"missing", guard, false])

      assert %{status: :failed, result: {:refused, {:release_check, _}}} = await(target, id)
    end

    assert {:ok, ^before} = OTP.inspect(target)
  end

  test "a killed worker blocks further work and keeps operation IDs idempotent", %{target: target} do
    {:ok, before} = OTP.inspect(target)

    assert {:ok, {:ok, "running"}} =
             call(target, :install, [
               "running",
               before.identity,
               ~c"missing",
               {:timer, :sleep, [:infinity]},
               false
             ])

    assert {:ok, {:ok, "running"}} =
             call(target, :install, ["running", %{}, ~c"other", nil, false])

    assert {:ok, {:error, :busy}} =
             call(target, :install, ["second", before.identity, ~c"missing", nil, false])

    assert {:ok, server} = OTP.call(target, :erlang, :whereis, [:jido_workspace_deploy_target])

    assert {:ok, {:monitors, [{:process, worker}]}} =
             OTP.call(target, :erlang, :process_info, [server, :monitors])

    assert {:ok, true} = OTP.call(target, :erlang, :exit, [worker, :kill])

    assert %{status: :recovery_required, result: {:worker_exit, :killed}} =
             await(target, "running")

    assert {:ok, {:error, :recovery_required}} =
             call(target, :install, ["blocked", before.identity, ~c"missing", nil, false])

    assert {:ok, {:ok, "recovery"}} =
             call(target, :install, ["recovery", before.identity, ~c"missing", nil, true])

    assert %{status: :failed} = await(target, "recovery")
    assert {:ok, %{runtime: %{blocked: true}}} = OTP.inspect(target)
  end

  test "an exception in the guard requires recovery", %{target: target} do
    {:ok, before} = OTP.inspect(target)

    assert {:ok, {:ok, "exception"}} =
             call(target, :install, [
               "exception",
               before.identity,
               ~c"missing",
               {:erlang, :error, [:guard_failed]},
               false
             ])

    assert %{status: :recovery_required, result: {:uncertain, {:error, :guard_failed}}} =
             await(target, "exception")

    assert {:ok, %{runtime: %{blocked: true}}} = OTP.inspect(target)
  end

  defp call(target, function, args),
    do: OTP.call(target, :jido_workspace_deploy_target, function, args)

  defp await(target, id, attempts \\ 100)
  defp await(_target, _id, 0), do: flunk("target operation did not finish")

  defp await(target, id, attempts) do
    assert {:ok, {:ok, entry}} = call(target, :status, [id])

    if entry.status == :running do
      Process.sleep(10)
      await(target, id, attempts - 1)
    else
      entry
    end
  end
end
