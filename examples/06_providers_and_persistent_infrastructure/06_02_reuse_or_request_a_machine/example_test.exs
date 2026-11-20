Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("machine_pool.ex", __DIR__)
Code.require_file("machine_provider.ex", __DIR__)

defmodule Jido.Workspace.Examples.PersistentMachineTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution, InfrastructureRef, Snapshot}
  alias Jido.Workspace.Examples.{MachinePool, MachineProvider}
  import Jido.Workspace.Examples.LifecycleSupport, only: [await: 3, configure: 1]

  @report "release report\n"

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))
    set_profile(:machine, %{pool: nil})
    :ok
  end

  test "attach validates the reference and selects the host profile before calling the provider" do
    {:ok, reference} = InfrastructureRef.new(MachinePool.provider(), "known-machine")
    {:ok, other} = InfrastructureRef.new("other-account", reference.resource_id)
    {:ok, snapshot} = Snapshot.new("reports", String.duplicate("a", 64))

    assert {:error, %Error{code: :infrastructure_required}} = Workspace.open(profile: :machine)

    for invalid <- [snapshot, Map.put(reference, :format, 2), :fresh] do
      assert {:error, %Error{code: :invalid_infrastructure}} =
               Workspace.open(profile: :machine, infrastructure: invalid)
    end

    assert {:error, %Error{code: :infrastructure_mismatch}} =
             Workspace.open(profile: :machine, infrastructure: other)

    assert {:error, %Error{code: :infrastructure_restore_unsupported}} =
             Workspace.open(profile: :machine, infrastructure: reference, from: snapshot)

    assert {:error,
            %Error{code: :unsupported_capability, details: %{capability: :infrastructure}}} =
             Workspace.open(profile: :memory, infrastructure: reference)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the local machine fixture"
  end

  test "close retains the same live machine and a fresh request gets a separate tree",
       %{tmp_dir: root} do
    pool = machine_pool(root)
    assert {:ok, first} = MachinePool.request(pool, "build-1")
    assert {:ok, ^first} = MachinePool.request(pool, "build-1")

    assert {:ok, %{started_at: started_at, running: true}} =
             MachinePool.inspect_machine(pool, first)

    reference_file = Path.join(root, "machine.json")
    File.write!(reference_file, Jason.encode!(first))

    {runtime_id, snapshot} =
      with_workspace(first, fn workspace ->
        assert {:ok, %{infrastructure: ^first}} = Workspace.info(workspace)
        assert :ok = Workspace.write(workspace, "build/draft; Q4.txt", @report)

        assert {:ok, %Execution{exit_status: 0, output: name}} =
                 Workspace.run(workspace, ["identity"])

        assert String.trim(name) == binary_part(first.resource_id, 0, 12)

        assert {:error, %Error{code: :infrastructure_busy}} =
                 Workspace.open(profile: :machine, infrastructure: first)

        assert {:ok, %Execution{exit_status: 0, output: @report}} =
                 Workspace.run(workspace, ["read", "draft; Q4.txt"], cwd: "build")

        assert {:ok, snapshot} = Workspace.save(workspace)
        assert :ok = Workspace.close(workspace)
        assert {:error, %Error{code: :closed}} = Workspace.read(workspace, "build/draft; Q4.txt")
        {name, snapshot}
      end)

    assert {:ok, %{started_at: ^started_at, running: true}} =
             MachinePool.inspect_machine(pool, first)

    serialized = reference_file |> File.read!() |> Jason.decode!()

    with_workspace(serialized, fn reopened ->
      assert {:ok, %{infrastructure: ^first}} = Workspace.info(reopened)
      assert {:ok, @report} = Workspace.read(reopened, "build/draft; Q4.txt")

      assert {:ok, %Execution{exit_status: 0, output: ^runtime_id}} =
               Workspace.run(reopened, ["identity"])

      assert {:ok, fresh} = MachinePool.request(pool, "build-2")
      assert fresh.resource_id != first.resource_id

      with_workspace(fresh, fn blank ->
        assert {:ok, %{infrastructure: ^fresh}} = Workspace.info(blank)
        assert {:error, %Error{code: :not_found}} = Workspace.read(blank, "build/draft; Q4.txt")

        assert {:ok, %Execution{exit_status: 0, output: fresh_id}} =
                 Workspace.run(blank, ["identity"])

        assert fresh_id != runtime_id
        assert :ok = Workspace.write(blank, "build/draft; Q4.txt", "separate\n")
      end)

      assert {:ok, @report} = Workspace.read(reopened, "build/draft; Q4.txt")
    end)

    assert {:ok, memory} = Workspace.open(profile: :memory, from: snapshot)

    try do
      assert {:ok, %{infrastructure: nil}} = Workspace.info(memory)
      assert {:ok, @report} = Workspace.read(memory, "build/draft; Q4.txt")
    after
      assert :ok = Workspace.close(memory)
    end
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the local machine fixture"
  end

  test "a stopped or unknown machine fails open and an explicit host restart preserves the tree",
       %{tmp_dir: root} do
    pool = machine_pool(root)
    assert {:ok, reference} = MachinePool.request(pool, "stop-restart")

    assert {:ok, unknown} =
             InfrastructureRef.new(MachinePool.provider(), String.duplicate("0", 64))

    assert {:error, %Error{code: :infrastructure_not_found}} =
             Workspace.open(profile: :machine, infrastructure: unknown)

    with_workspace(reference, fn workspace ->
      assert :ok = Workspace.write(workspace, "result.txt", @report)
    end)

    assert {_, 0} = MachinePool.docker(pool, ["stop", "--time", "0", reference.resource_id])

    assert {:error, %Error{code: :infrastructure_unavailable}} =
             Workspace.open(profile: :machine, infrastructure: reference)

    assert {:ok, %{running: false}} = MachinePool.inspect_machine(pool, reference)
    assert {_, 0} = MachinePool.docker(pool, ["start", reference.resource_id])

    with_workspace(reference, fn workspace ->
      assert {:ok, %{infrastructure: ^reference}} = Workspace.info(workspace)
      assert {:ok, @report} = Workspace.read(workspace, "result.txt")
    end)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the local machine fixture"
  end

  test "a mismatched provider acknowledgment fails open and releases only the attempted lease",
       %{tmp_dir: root} do
    pool = machine_pool(root)
    assert {:ok, expected} = MachinePool.request(pool, "expected")
    assert {:ok, other} = MachinePool.request(pool, "other")
    set_profile(:mismatch, %{pool: pool, reported: other})

    with_workspace(other, fn other_workspace ->
      assert {:error, %Error{code: :infrastructure_mismatch}} =
               Workspace.open(profile: :mismatch, infrastructure: expected)

      assert :ok = Workspace.write(other_workspace, "still-owned", "ready")

      with_workspace(expected, fn workspace ->
        assert {:ok, %{infrastructure: ^expected}} = Workspace.info(workspace)
      end)
    end)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the local machine fixture"
  end

  test "owner exit releases the session and keeps the host's machine and files", %{tmp_dir: root} do
    pool = machine_pool(root)
    assert {:ok, reference} = MachinePool.request(pool, "owner-exit")

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(owner)
    on_exit(fn -> Process.exit(owner, :kill) end)

    assert {:ok, workspace} =
             Workspace.open(profile: :machine, infrastructure: reference, owner: owner)

    assert :ok = Workspace.write(workspace, "saved-on-machine.txt", @report)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    await(
      fn ->
        match?({:error, %Error{code: :closed}}, Workspace.read(workspace, "saved-on-machine.txt"))
      end,
      "The old handle still has access after the owner exited",
      4_000
    )

    with_workspace(reference, fn reopened ->
      assert {:ok, @report} = Workspace.read(reopened, "saved-on-machine.txt")
    end)
  end

  defp machine_pool(root) do
    image = System.get_env("JIDO_SANDBOX_IMAGE", "alpine:3.20")
    assert {:ok, pool} = MachinePool.start(Path.join(root, "machines"), image)
    on_exit(fn -> assert :ok = MachinePool.destroy(pool) end)
    set_profile(:machine, %{pool: pool})
    pool
  end

  defp with_workspace(infrastructure, action) do
    assert {:ok, workspace} = Workspace.open(profile: :machine, infrastructure: infrastructure)

    try do
      action.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp set_profile(name, options) do
    profile = %{
      provider: {MachineProvider, options},
      infrastructure: MachinePool.provider(),
      policy: :full_access,
      require: %{network: :disabled},
      store: "reports",
      tools: ["identity", "read"]
    }

    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, name, profile))
  end
end
