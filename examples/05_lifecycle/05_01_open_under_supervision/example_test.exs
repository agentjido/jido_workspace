Code.require_file("../support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.OwnedReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.Examples.OwnedReport
  import Jido.Workspace.Examples.LifecycleSupport

  setup %{tmp_dir: root} do
    configure(root)
    %{owners: start_supervised!(Task.Supervisor)}
  end

  test "an exited owner cannot acquire a profiled workspace", %{owners: owners} do
    owner = start_owner(owners)
    ref = Process.monitor(owner)
    assert :ok = Task.Supervisor.terminate_child(owners, owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, :shutdown}

    assert {:error, %Workspace.Error{code: :owner_unavailable, operation: :open}} =
             Workspace.open(profile: :memory, owner: owner)
  end

  test "stopping the memory owner releases the tree and preserves the saved report",
       %{owners: owners} do
    owner = start_owner(owners)
    {workspace, snapshot} = prepare(:memory, owner)
    {controller, memory} = provider(workspace, :memory)

    assert_processes_stop(controller, memory.lifetime, fn ->
      assert :ok = Task.Supervisor.terminate_child(owners, owner)
    end)

    assert [] = Jido.Shell.VFS.list_mounts(memory.id)
    assert_recovery(workspace, :memory, snapshot)
  end

  test "an abrupt memory controller exit releases the tree even when the owner survives",
       %{owners: owners} do
    owner = start_owner(owners)
    {workspace, snapshot} = prepare(:memory, owner)
    {controller, memory} = provider(workspace, :memory)

    assert_processes_stop(controller, memory.lifetime, fn -> Process.exit(controller, :kill) end)

    assert Process.alive?(owner)
    assert [] = Jido.Shell.VFS.list_mounts(memory.id)
    assert_recovery(workspace, :memory, snapshot)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to verify release on Docker"
  end

  test "stopping the Docker owner removes its container and root", %{owners: owners} do
    owner = start_owner(owners)
    {workspace, snapshot} = prepare(:docker, owner)
    {controller, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)

    assert {:ok, %{exit_status: 0}} = Workspace.run(workspace, ["cat", "report.txt"])
    assert [_] = containers(sandbox)

    assert_processes_stop(controller, sandbox.pid, fn ->
      assert :ok = Task.Supervisor.terminate_child(owners, owner)
    end)

    assert [] = containers(sandbox)
    refute File.exists?(sandbox.root)
    assert_recovery(workspace, :docker, snapshot)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to verify active container cleanup"
  end

  test "an abrupt Docker controller exit removes a running container and its root",
       %{owners: owners} do
    owner = start_owner(owners)
    {workspace, snapshot} = prepare(:docker, owner)
    {controller, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)

    command =
      Task.async(fn ->
        Workspace.run(workspace, ["sleep", "45"], timeout_ms: 50_000)
      end)

    await(fn -> container_running(sandbox) end, "No running container", 10_000)
    assert_processes_stop(controller, sandbox.pid, fn -> Process.exit(controller, :kill) end)

    assert {:error, %Workspace.Error{code: :closed}} = Task.await(command)
    assert Process.alive?(owner)
    assert [] = containers(sandbox)
    refute File.exists?(sandbox.root)
    assert_recovery(workspace, :docker, snapshot)
  end

  defp start_owner(owners) do
    {:ok, owner} =
      Task.Supervisor.start_child(owners, fn ->
        receive do
          :stop -> :ok
        end
      end)

    owner
  end

  defp prepare(profile, owner) do
    assert {:ok, workspace, snapshot} = OwnedReport.prepare(profile, owner, "Saved")
    assert {:ok, %{owner: ^owner}} = Workspace.info(workspace)
    assert :ok = Workspace.write(workspace, "report.txt", "Unsaved edit")
    {workspace, snapshot}
  end

  defp assert_recovery(workspace, profile, snapshot) do
    assert {:error, %Workspace.Error{code: :closed}} = Workspace.read(workspace, "report.txt")

    assert {:error, %Workspace.Error{code: :closed}} =
             Workspace.write(workspace, "report.txt", "X")

    assert {:error, %Workspace.Error{code: :closed}} = Workspace.save(workspace)
    assert {:ok, reopened} = Workspace.open(profile: profile, from: snapshot)

    try do
      assert {:ok, "Saved"} = Workspace.read(reopened, "report.txt")
    after
      assert :ok = Workspace.close(reopened)
    end
  end

  defp assert_processes_stop(controller, provider, stop) do
    controller_ref = Process.monitor(controller)
    provider_ref = Process.monitor(provider)
    stop.()

    assert_receive {:DOWN, ^controller_ref, :process, ^controller, _}, 15_000
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :normal}, 15_000
  end
end
