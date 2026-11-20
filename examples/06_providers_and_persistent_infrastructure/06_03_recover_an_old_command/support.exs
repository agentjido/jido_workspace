Code.require_file("../06_02_reuse_or_request_a_machine/machine_pool.ex", __DIR__)
Code.require_file("../06_02_reuse_or_request_a_machine/machine_provider.ex", __DIR__)
Code.require_file("recovery_provider.ex", __DIR__)
Code.require_file("recovery_host.ex", __DIR__)

defmodule Jido.Workspace.Examples.RecoverySupport do
  @moduledoc false

  import ExUnit.Assertions

  alias Jido.Workspace.{CommandRef, InfrastructureRef}
  alias Jido.Workspace.Examples.{MachinePool, RecoveryHost, RecoveryProvider}

  @provider_source Path.join(__DIR__, "recovery_provider.ex")

  def preserve_configuration do
    profiles = Application.fetch_env(:jido_workspace, :profiles)
    stores = Application.fetch_env(:jido_workspace, :stores)

    ExUnit.Callbacks.on_exit(fn ->
      restore_env(:profiles, profiles)
      restore_env(:stores, stores)
    end)

    :ok
  end

  def peer do
    paths = Enum.map(:code.get_path(), &Path.expand(List.to_string(&1)))
    args = [~c"+S", ~c"2:2", ~c"-pa" | Enum.map(paths, &String.to_charlist/1)]

    assert {:ok, peer, _} =
             :peer.start(%{connection: :standard_io, args: args, wait_boot: 10_000})

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(peer), do: :peer.stop(peer)
    end)

    assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:jido_workspace])
    assert is_list(:peer.call(peer, Code, :require_file, [@provider_source]))
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    stores = Application.fetch_env!(:jido_workspace, :stores)
    assert :ok = :peer.call(peer, Application, :put_env, [:jido_workspace, :profiles, profiles])
    assert :ok = :peer.call(peer, Application, :put_env, [:jido_workspace, :stores, stores])
    peer
  end

  def await_start(tree, ref) do
    await_contents(Path.join(RecoveryHost.job_path(tree, ref), "starts"), "started\n")
  end

  def await_contents(path, contents) do
    await_file(path, contents, System.monotonic_time(:millisecond) + 10_000)
  end

  defp await_file(path, contents, deadline) do
    case File.read(path) do
      {:ok, ^contents} ->
        :ok

      other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          await_file(path, contents, deadline)
        else
          flunk("expected contents were not written to #{path}: #{inspect(other)}")
        end
    end
  end

  def fixture(root) do
    image = System.get_env("JIDO_SANDBOX_IMAGE", "alpine:3.20")
    assert {:ok, pool} = MachinePool.start(Path.join(root, "machines"), image)
    ExUnit.Callbacks.on_exit(fn -> assert :ok = MachinePool.destroy(pool) end)
    assert {:ok, machine} = MachinePool.request(pool, "command-recovery")
    host = ExUnit.Callbacks.start_supervised!({RecoveryHost, {pool, machine}})
    options = RecoveryHost.options(host)

    Application.put_env(:jido_workspace, :profiles, %{
      run: profile(options, [:read, :write, :execute, :save]),
      lost_reply: profile(Map.put(options, :lose_reply, true), [:read, :write, :execute, :save]),
      recovery: profile(options, [:recover]),
      memory: %{provider: :memory, policy: :full_access, store: "results"}
    })

    Application.put_env(:jido_workspace, :stores, %{"results" => Path.join(root, "results")})
    %{pool: pool, host: host, machine: machine, tree: MachinePool.tree(pool, machine)}
  end

  def profile(options, policy) do
    %{
      provider: {RecoveryProvider, options},
      infrastructure: MachinePool.provider(),
      policy: policy,
      require: %{network: :disabled},
      store: "results",
      tools: ["write-report"]
    }
  end

  def reference(machine_id, command_id) do
    assert {:ok, machine} = InfrastructureRef.new(MachinePool.provider(), machine_id)
    new_reference(machine, command_id)
  end

  def new_reference(machine, command_id) do
    assert {:ok, ref} = CommandRef.new(machine, command_id)
    ref
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:jido_workspace, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:jido_workspace, key)
end
