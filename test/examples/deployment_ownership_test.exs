defmodule Jido.Workspace.DeploymentOwnershipTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Jido.Workspace.{Deploy, Sandbox}
  alias Jido.Workspace.Deploy.{Artifact, Recipe, Snapshot}

  test "an old worker cannot change a replacement deployment after controller loss" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    {:ok, target} = Deploy.source_target(sandbox, "app")
    {:ok, controller} = Deploy.connect(target)
    {:ok, snapshot} = Snapshot.new(%{"input" => %{bytes: "source", mode: 0o644}})
    {:ok, artifact} = Artifact.new(:source, "1", snapshot)
    gate = Path.join(sandbox.root, "gate")

    recipe = %Recipe{
      prepare: [{"/bin/sh", ["-c", ~s(while [ ! -f "$1" ]; do sleep 0.01; done), "wait", gate]}]
    }

    {:ok, old} = Deploy.prepare(controller, artifact, recipe: recipe)
    {:ok, _} = Deploy.apply(controller, old)
    {task, _} = :sys.get_state(controller).task
    monitor = Process.monitor(task.pid)
    wait_for_command(sandbox)
    :erlang.suspend_process(task.pid)
    Process.exit(controller, :kill)
    ref = Process.monitor(controller)
    assert_receive {:DOWN, ^ref, :process, ^controller, _}

    {:ok, replacement} = Deploy.connect(%{target | path: "./app/."})
    service = %{executable: "/bin/sleep", args: ["30"]}
    {:ok, next} = Deploy.prepare(replacement, artifact, recipe: %Recipe{service: service})
    {:ok, id} = Deploy.apply(replacement, next)
    assert {:ok, %{status: :succeeded}} = Deploy.await(replacement, id)
    {:ok, service_id} = Sandbox.read(sandbox, "app/.service")
    :ok = Sandbox.write(sandbox, "gate", "go")
    :erlang.resume_process(task.pid)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 3_000
    assert {:ok, "releases/" <> ^id} = Sandbox.read_link(sandbox, "app/current")
    assert {:ok, ^service_id} = Sandbox.read(sandbox, "app/.service")
    assert {:ok, %{status: :running}} = Sandbox.service_status(sandbox, service_id)
  end

  test "generations reject stale file, service, and BEAM requests" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    {:ok, old} = Sandbox.claim_deployment(sandbox, {sandbox.id, "app"})
    {:ok, current} = Sandbox.claim_deployment(sandbox, {sandbox.id, "app"})
    assert {:error, :stale_deployment} = Sandbox.write(old, "marker", "bad")
    assert {:error, :stale_deployment} = Sandbox.replace_link(old, "current", "release", "x")
    assert {:error, :stale_deployment} = Sandbox.stop_service(old, "service")
    assert {:error, :stale_deployment} = Sandbox.call(old, "service", Kernel, :node, [])
    assert :ok = Sandbox.write(current, "marker", "current")
    {:ok, independent} = Sandbox.claim_deployment(sandbox, {sandbox.id, "other"})
    assert :ok = Sandbox.write(independent, "other", "ok")
    assert :ok = Sandbox.write(current, "marker", "still current")
  end

  test "controller death revokes ownership before a replacement connects" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, handle} = Sandbox.claim_deployment(sandbox, {sandbox.id, "app"})
        send(parent, {:owned, handle})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:owned, handle}
    assert {:error, :deployment_owned} = Sandbox.claim_deployment(sandbox, {sandbox.id, "app"})
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert {:error, :stale_deployment} = Sandbox.write(handle, "marker", "bad")
    assert {:ok, _} = Sandbox.claim_deployment(sandbox, {sandbox.id, "app"})
  end

  defp wait_for_command(sandbox, remaining \\ 200)
  defp wait_for_command(_, 0), do: flunk("Preparation did not start")

  defp wait_for_command(sandbox, remaining) do
    {:ok, %{services: services}} = Sandbox.info(sandbox)

    if Enum.any?(services, fn {_, service} -> service.status == :running end) do
      :ok
    else
      Process.sleep(10)
      wait_for_command(sandbox, remaining - 1)
    end
  end
end
