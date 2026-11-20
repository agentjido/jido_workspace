Code.require_file("support.exs", __DIR__)

defmodule Jido.Workspace.Examples.RecoverOldCommandTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Jido.Workspace
  alias Jido.Workspace.{CommandRef, Error, InfrastructureRef}
  alias Jido.Workspace.Examples.{MachinePool, MachineProvider, RecoveryHost, RecoveryProvider}

  import Jido.Workspace.Examples.RecoverySupport

  defmodule UncertainProvider do
    @behaviour Jido.Workspace.Provider

    @impl true
    defdelegate provision(lease, settings, capture), to: RecoveryProvider
    @impl true
    defdelegate file(handle, request), to: RecoveryProvider
    @impl true
    defdelegate capture(handle, limits), to: RecoveryProvider
    @impl true
    defdelegate release(lease, options), to: RecoveryProvider
    @impl true
    defdelegate run(handle, command), to: RecoveryProvider

    @impl true
    def recover_command(_, :stop, _, _), do: {:ok, :running}

    def recover_command(_, :wait, _, caller) do
      send(caller, {:recovery_waiting, self()})
      Process.sleep(:infinity)
    end
  end

  setup do
    preserve_configuration()
  end

  test "only a recovery-capable profile with the recovery grant can act" do
    Application.put_env(:jido_workspace, :profiles, %{
      memory: %{provider: :memory, policy: :full_access},
      no_hook: %{
        provider: {MachineProvider, %{}},
        infrastructure: MachinePool.provider(),
        policy: :full_access
      },
      no_grant: profile(%{}, [:read, :execute])
    })

    ref = reference("provider-resource", "command-1")

    assert {:error, %Error{code: :invalid_command_reference}} =
             Workspace.recover_command(:no_grant, ref.infrastructure, :inspect)

    assert {:error, %Error{code: :invalid_input}} =
             Workspace.recover_command(:no_grant, ref, :restart)

    assert {:error, %Error{code: :invalid_input}} =
             Workspace.recover_command(:no_grant, ref, :wait, timeout_ms: 0)

    for name <- [:no_hook, :memory] do
      assert {:error,
              %Error{code: :unsupported_capability, details: %{capability: :command_recovery}}} =
               Workspace.recover_command(name, ref, :inspect)
    end

    assert {:error, %Error{code: :policy_denied, details: %{action: :recover}}} =
             Workspace.recover_command(:no_grant, ref, :stop)

    assert {:ok, other} = InfrastructureRef.new("other", "provider-resource")
    assert {:ok, other_ref} = CommandRef.new(other, "command-1")

    assert {:error, %Error{code: :infrastructure_mismatch}} =
             Workspace.recover_command(:no_grant, other_ref, :inspect)

    assert {:ok, ws} = Workspace.open(profile: :memory)

    try do
      assert {:error, %Error{code: :unsupported_capability}} =
               Workspace.run(ws, ["echo", "test"], command: ref)

      assert {:error, %Error{}} =
               Workspace.batch(ws, [{:write, "before", "data"}, {:run, ["echo"], [command: ref]}])

      assert {:error, %Error{code: :not_found}} = Workspace.read(ws, "before")
    after
      assert :ok = Workspace.close(ws)
    end
  end

  test "an unconfirmed stop or a timed out recovery call cannot report exit" do
    recovery = %{profile(%{}, [:recover]) | provider: {UncertainProvider, self()}}
    Application.put_env(:jido_workspace, :profiles, %{recovery: recovery})
    ref = reference("provider-resource", "command-1")

    assert {:error, %Error{code: :quiescence_unknown}} =
             Workspace.recover_command(:recovery, ref, :stop)

    task =
      Task.async(fn -> Workspace.recover_command(:recovery, ref, :wait, timeout_ms: 750) end)

    assert_receive {:recovery_waiting, worker}, 1_000
    monitor = Process.monitor(worker)
    assert {:error, %Error{code: :quiescence_unknown}} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
  end

  @tag :tmp_dir
  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the local recovery fixture"
  end

  test "a lost launch reply leaves a writer recoverable by its original reference", %{
    tmp_dir: root
  } do
    %{machine: machine, tree: tree} = fixture(root)
    ref = new_reference(machine, "lost-reply")
    json = Jason.encode!(ref)
    ref_path = Path.join(root, "command.json")
    File.write!(ref_path, json)
    assert {:ok, ws} = Workspace.open(profile: :lost_reply, infrastructure: machine)

    assert {:error, %Error{code: :infrastructure_mismatch}} =
             Workspace.run(ws, ["write-report"], command: reference("other-resource", "job"))

    assert {:error, %Error{code: :quiescence_unknown}} =
             Workspace.run(ws, ["write-report"], command: ref)

    assert :ok = await_start(tree, ref)

    assert {:error, %Error{code: :quiescence_unknown}} =
             Workspace.write(ws, "error.txt", "blocked")

    assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(ws)

    assert {:error, %Error{code: :infrastructure_busy}} =
             Workspace.open(profile: :run, infrastructure: machine)

    recovered = ref_path |> File.read!() |> Jason.decode!()

    assert {:ok, %{status: :running, exit_status: nil}} =
             Workspace.recover_command(:recovery, recovered, :inspect)

    assert {:ok, %{status: :running}} =
             Workspace.recover_command(:recovery, recovered, :wait, timeout_ms: 450)

    assert {:error, %Error{code: :command_not_found}} =
             Workspace.recover_command(:recovery, new_reference(machine, "other"), :inspect)

    path = RecoveryHost.job_path(tree, ref)
    assert :ok = File.touch(Path.join(path, "finish"))

    assert {:ok, %{status: :exited, exit_status: 0}} =
             Workspace.recover_command(:recovery, recovered, :wait, timeout_ms: 5_000)

    assert :ok = Workspace.close(ws)
    assert {:ok, retry} = Workspace.open(profile: :run, infrastructure: machine)

    try do
      assert {:error, %Error{code: :command_reference_used}} =
               Workspace.run(retry, ["write-report"], command: recovered)

      assert File.read!(Path.join(path, "starts")) == "started\n"
      assert File.read!(Path.join(path, "report")) == "complete\n"
      assert :ok = Workspace.write(retry, "after.txt", "usable")
    after
      assert :ok = Workspace.close(retry)
    end
  end

  @tag :tmp_dir
  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the local recovery fixture"
  end

  test "a fresh BEAM stops the old writer after a hard VM exit", %{tmp_dir: root} do
    %{pool: pool, machine: machine, tree: tree} = fixture(root)
    ref = new_reference(machine, "vm-exit")
    ref_path = Path.join(root, "command.json")
    File.write!(ref_path, Jason.encode!(ref))
    assert {:ok, %{started_at: started_at}} = MachinePool.inspect_machine(pool, machine)
    old = peer()
    monitor = Process.monitor(old)

    script = """
    spawn(fn ->
      {:ok, workspace} = Jido.Workspace.open(profile: :run, infrastructure: ref.infrastructure)
      Jido.Workspace.run(workspace, ["write-report"], command: ref)
    end)
    :submitted
    """

    assert {:submitted, _} = :peer.call(old, Code, :eval_string, [script, [ref: ref]])
    assert :ok = await_start(tree, ref)
    assert :ok = :peer.cast(old, System, :halt, [73])
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 10_000

    recovered = ref_path |> File.read!() |> Jason.decode!()
    fresh = peer()
    assert {:ok, %{status: :running}} = recover_on(fresh, recovered, :inspect)

    assert {:error, %Error{code: :infrastructure_busy}} =
             :peer.call(fresh, Workspace, :open, [[profile: :run, infrastructure: machine]])

    assert {:ok, %{status: :exited, exit_status: status} = result} =
             recover_on(fresh, recovered, :stop)

    assert status != 0
    assert {:ok, ^result} = recover_on(fresh, recovered, :stop)
    assert {:ok, ^result} = recover_on(fresh, recovered, :wait)
    assert File.read!(Path.join(RecoveryHost.job_path(tree, ref), "starts")) == "started\n"

    assert {:ok, %{running: true, started_at: ^started_at}} =
             MachinePool.inspect_machine(pool, machine)

    assert {:error, %Error{code: :infrastructure_busy}} =
             :peer.call(fresh, Workspace, :open, [[profile: :run, infrastructure: machine]])
  end

  defp recover_on(peer, ref, action),
    do: :peer.call(peer, Workspace, :recover_command, [:recovery, ref, action])
end
