Code.require_file("../06_03_recover_an_old_command/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.ExternalMaintainerTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  import Jido.Workspace.Examples.RecoverySupport

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.{MachinePool, RecoveryHost, RecoveryProvider}

  @maintainer_script """
  printf '%s\n' "$1" > review.txt
  while [ ! -f continue-review ]; do sleep 0.05; done
  printf 'finished review\n' > review-log.txt
  while :; do sleep 0.05; done
  """

  setup do
    preserve_configuration()
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the local maintenance console"
  end

  test "the Workspace lease and the external console share one writer slot", %{tmp_dir: root} do
    %{pool: pool, host: host, machine: machine, tree: tree} = fixture(root)
    assert {:ok, original} = MachinePool.inspect_machine(pool, machine)
    assert {:ok, workspace} = Workspace.open(profile: :run, infrastructure: machine)
    assert :ok = Workspace.write(workspace, "draft.txt", "initial draft\n")
    assert {:ok, old_lease} = RecoveryHost.current_writer(host, machine)
    maintenance_id = "review-change-1"
    ref = new_reference(machine, "before-review")
    started = Task.async(fn -> Workspace.run(workspace, ["write-report"], command: ref) end)
    assert :ok = await_start(tree, ref)

    assert {:error, :infrastructure_busy} =
             RecoveryHost.begin_maintenance(host, machine, maintenance_id)

    assert {:error, :cleanup_unconfirmed} = RecoveryHost.revoke_writer(host, machine, old_lease)

    assert {:error, :infrastructure_busy} =
             RecoveryHost.begin_maintenance(host, machine, maintenance_id)

    assert :ok = File.touch(Path.join(RecoveryHost.job_path(tree, ref), "finish"))
    assert {:ok, %Execution{exit_status: 0}} = Task.await(started, 10_000)
    assert :ok = RecoveryHost.revoke_writer(host, machine, old_lease)
    assert_workspace_transport_cannot_begin_maintenance(host, machine)

    assert {:ok, console} = RecoveryHost.begin_maintenance(host, machine, maintenance_id)
    assert {:ok, ^console} = RecoveryHost.begin_maintenance(host, machine, maintenance_id)
    assert_workspace_busy(machine)

    assert {:error, %Error{code: :lease_revoked}} = Workspace.save(workspace)

    assert {:error, %Error{code: :lease_revoked}} =
             Workspace.write(workspace, "draft.txt", "stale")

    assert :ok = Workspace.close(workspace)
    assert_workspace_busy(machine)

    assert :ok =
             RecoveryHost.run_maintenance(host, machine, maintenance_id, [
               "/bin/sh",
               "-eu",
               "-c",
               @maintainer_script,
               "review",
               "approved; Q4"
             ])

    assert :ok = await_contents(Path.join(tree, "review.txt"), "approved; Q4\n")
    assert {:error, :maintenance_not_found} = RecoveryHost.end_maintenance(host, machine, "other")

    assert {:error, :cleanup_unconfirmed} =
             RecoveryHost.end_maintenance(host, machine, maintenance_id)

    assert {:error, :maintenance_closed} =
             RecoveryHost.run_maintenance(host, machine, maintenance_id, ["/bin/true"])

    assert_workspace_busy(machine)
    assert :ok = File.touch(Path.join(tree, "continue-review"))
    assert :ok = await_contents(Path.join(tree, "review-log.txt"), "finished review\n")
    assert_workspace_busy(machine)

    # The host controls the engine. The maintainer only has the console.
    assert {_, 0} = MachinePool.docker(pool, ["kill", console.container])
    assert {_, 0} = MachinePool.docker(pool, ["wait", console.container])
    assert_workspace_busy(machine)
    assert :ok = RecoveryHost.end_maintenance(host, machine, maintenance_id)
    assert {_, status} = MachinePool.docker(pool, ["start", console.container])
    assert status != 0
    assert {:ok, ^original} = MachinePool.inspect_machine(pool, machine)

    assert {:ok, replacement} = Workspace.open(profile: :run, infrastructure: machine)

    try do
      assert :ok = RecoveryHost.end_maintenance(host, machine, maintenance_id)
      assert_workspace_busy(machine)
      assert {:ok, "approved; Q4\n"} = Workspace.read(replacement, "review.txt")
      assert :ok = Workspace.write(replacement, "published.txt", "ready\n")
      assert {:ok, saved} = Workspace.save(replacement)
      assert {:ok, restored} = Workspace.open(profile: :memory, from: saved)

      try do
        assert {:ok, "initial draft\n"} = Workspace.read(restored, "draft.txt")
        assert {:ok, "approved; Q4\n"} = Workspace.read(restored, "review.txt")
        assert {:ok, "finished review\n"} = Workspace.read(restored, "review-log.txt")
        assert {:ok, "ready\n"} = Workspace.read(restored, "published.txt")
      after
        assert :ok = Workspace.close(restored)
      end
    after
      assert :ok = Workspace.close(replacement)
    end

    assert {:error, :maintenance_closed} =
             RecoveryHost.begin_maintenance(host, machine, maintenance_id)
  end

  defp assert_workspace_transport_cannot_begin_maintenance(host, machine) do
    %{port: port, token: token} = RecoveryHost.options(host)

    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, port, RecoveryProvider.socket_options(), 1_000)

    try do
      request = {token, {:begin_maintenance, machine, "wrong-authority"}}
      assert :ok = :gen_tcp.send(socket, :erlang.term_to_binary(request))
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    after
      :gen_tcp.close(socket)
    end
  end

  defp assert_workspace_busy(machine) do
    assert {:error, %Error{code: :infrastructure_busy}} =
             Workspace.open(profile: :run, infrastructure: machine)
  end
end
