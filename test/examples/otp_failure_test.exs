defmodule Jido.Workspace.Deploy.OTPFailureTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 90_000
  alias Jido.Workspace.Deploy
  alias Jido.Workspace.Deploy.OTP
  alias Jido.Workspace.Sandbox

  test "callback failure requires recovery; a node restart loses live process state" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    artifacts = Jido.Workspace.Deploy.Test.Releases.build(Path.join(sandbox.root, "build"))
    {:ok, target} = OTP.start(sandbox, "counter", artifacts["1"])
    {:ok, session} = Deploy.connect(target)
    {:ok, %{identity: before}} = Deploy.inspect(session)
    {:ok, {old_pid, ~c"1", _}} = OTP.call(target, :counter_server, :inspect, [])
    {:ok, %{count: 19}} = OTP.call(target, :counter_server, :add, [9])
    {:ok, plan} = Deploy.prepare(session, artifacts["3"])
    {:ok, id} = Deploy.apply(session, plan)
    assert {:ok, %{status: :recovery_required}} = Deploy.await(session, id)

    # OTP can restart after the point of no return. Reconnect is explicit.
    assert {:ok, ^target} = reconnect(target, 100)
    assert {:ok, %{identity: after_restart}} = Deploy.inspect(session)
    refute before.generation == after_restart.generation

    assert {:ok, {new_pid, ~c"1", %{count: 10, requests: 0}}} =
             OTP.call(target, :counter_server, :inspect, [])

    refute old_pid == new_pid

    {:ok, ordinary} = Deploy.prepare(session, artifacts["2"])
    assert {:error, :recovery_required} = Deploy.apply(session, ordinary)
    {:ok, recovery} = Deploy.recover(session, id, artifacts["2"])
    {:ok, recovery_id} = Deploy.apply(session, recovery)
    assert {:ok, %{status: :succeeded, recovery_of: ^id}} = Deploy.await(session, recovery_id)

    assert {:ok, {^new_pid, ~c"2", %{total: 10, requests: 0}}} =
             OTP.call(target, :counter_server, :inspect, [])
  end

  defp reconnect(_, 0), do: {:error, :reconnect_timeout}

  defp reconnect(target, attempts) do
    case OTP.reconnect(target) do
      {:ok, _} = result ->
        result

      _ ->
        Process.sleep(50)
        reconnect(target, attempts - 1)
    end
  end
end
