Code.require_file("../support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.FinishWorkTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.Error
  alias Jido.Workspace.Examples.FinishWork
  import Jido.Workspace.Examples.LifecycleSupport

  setup %{tmp_dir: root}, do: configure(root)

  test "close waits for an accepted save and blocks another writer after the wait expires" do
    {workspace, first} = prepare(:memory)
    assert :ok = Workspace.write(workspace, "report.txt", "New report")
    {controller, memory} = provider(workspace, :memory)

    {save, retry} =
      paused(memory.lifetime, fn ->
        save = Task.async(fn -> Workspace.save(workspace) end)
        await_job(controller, :save)
        assert {:ok, %{phase: :saving}} = Workspace.info(workspace)

        assert {:cleanup_unconfirmed, ^workspace, ^first} =
                 FinishWork.close(workspace, first, 100)

        assert {:ok, %{phase: :closing}} = Workspace.info(workspace)
        assert_closed_to_work(workspace)

        retry = Task.async(fn -> Workspace.close(workspace, timeout_ms: 5_000) end)

        await(
          fn ->
            %{closing: waiters} = :sys.get_state(controller)
            Enum.any?(waiters, fn {_, {{pid, _}, _}} -> pid == retry.pid end)
          end,
          "The retry did not join the close request"
        )

        {save, retry}
      end)

    assert {:ok, later} = Task.await(save)
    assert later != first
    assert :ok = Task.await(retry)
    assert {:closed, ^later} = FinishWork.close(workspace, later, 5_000)
    assert :ok = Workspace.close(workspace)
    assert_report(first, "Original")
    assert_report(later, "New report")
  end

  test "close releases the workspace after a failed save and preserves the earlier snapshot",
       %{tmp_dir: root} do
    {workspace, first} = prepare(:memory)
    {controller, memory} = provider(workspace, :memory)

    save =
      paused(memory.lifetime, fn ->
        save = Task.async(fn -> Workspace.save(workspace) end)
        await_job(controller, :save)

        assert {:error, %Error{code: :cleanup_unconfirmed}} =
                 Workspace.close(workspace, timeout_ms: 100)

        Application.put_env(:jido_workspace, :stores, %{
          "reports" => Path.join(root, "report-file")
        })

        File.write!(Path.join(root, "report-file"), "not a directory")
        save
      end)

    assert {:error, %Error{operation: :save}} = Task.await(save)
    assert :ok = Workspace.close(workspace)
    Application.put_env(:jido_workspace, :stores, %{"reports" => root})
    assert_report(first, "Original")
  end

  test "an admitted memory command can finish during close" do
    {workspace, snapshot} = prepare(:memory)
    {controller, memory} = provider(workspace, :memory)

    command =
      paused(memory.lifetime, fn ->
        command = Task.async(fn -> Workspace.run(workspace, ["cat", "report.txt"]) end)
        await_job(controller, :run)

        assert {:cleanup_unconfirmed, ^workspace, ^snapshot} =
                 FinishWork.close(workspace, snapshot, 100)

        assert_closed_to_work(workspace)
        command
      end)

    assert {:ok, %{exit_status: 0, output: "Original"}} = Task.await(command)
    assert :ok = Workspace.close(workspace)
    assert_report(snapshot, "Original")
  end

  test "the caller's wait also bounds an in-progress release" do
    {workspace, _snapshot} = prepare(:memory)
    {controller, memory} = provider(workspace, :memory)

    paused(memory.lifetime, fn ->
      assert {:error, %Error{code: :cleanup_unconfirmed}} =
               Workspace.close(workspace, timeout_ms: 100)

      await_job(controller, :release)
      assert_closed_to_work(workspace)
    end)

    assert :ok = Workspace.close(workspace)
    assert_closed_to_work(workspace)
  end

  test "loss of the controller does not confirm release" do
    {workspace, snapshot} = prepare(:memory)
    {controller, _memory} = provider(workspace, :memory)
    reference = Process.monitor(controller)
    Process.exit(controller, :kill)
    assert_receive {:DOWN, ^reference, :process, ^controller, :killed}

    assert {:cleanup_unconfirmed, ^workspace, ^snapshot} =
             FinishWork.close(workspace, snapshot, 100)

    assert_closed_to_work(workspace)
    assert_report(snapshot, "Original")
  end

  test "a failed provider release keeps the workspace closed to new work" do
    {workspace, snapshot} = prepare(:memory)
    {_controller, memory} = provider(workspace, :memory)
    reference = Process.monitor(memory.lifetime)
    Process.exit(memory.lifetime, :kill)
    assert_receive {:DOWN, ^reference, :process, _, :killed}

    assert {:cleanup_unconfirmed, ^workspace, ^snapshot} =
             FinishWork.close(workspace, snapshot, 100)

    assert_closed_to_work(workspace)
    assert {:error, %Error{code: :cleanup_unconfirmed}} = Workspace.close(workspace)
    assert_report(snapshot, "Original")
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to race close with a live Docker command"
  end

  test "an admitted Docker command finishes before confirmed close" do
    {workspace, snapshot} = prepare(:docker)
    {_controller, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)

    # The test releases the command with a pipe outside the managed tree.
    command =
      Task.async(fn ->
        Workspace.run(
          workspace,
          [
            "sh",
            "-c",
            ~S(mkfifo /tmp/finish && read -r result </tmp/finish && printf '%s' "$result")
          ],
          timeout_ms: 30_000
        )
      end)

    container = await(fn -> container_running(sandbox) end, "No running container", 10_000)

    pipe_ready = fn ->
      match?({_, 0}, docker(["exec", container, "test", "-p", "/tmp/finish"]))
    end

    await(pipe_ready, "The command did not create its pipe", 5_000)

    assert {:cleanup_unconfirmed, ^workspace, ^snapshot} =
             FinishWork.close(workspace, snapshot, 100)

    assert_closed_to_work(workspace)

    assert {_, 0} =
             docker(["exec", container, "sh", "-c", ~S(printf 'finished\n' >/tmp/finish)])

    assert {:ok, %{exit_status: 0, output: "finished"}} = Task.await(command, 10_000)
    assert {:closed, ^snapshot} = FinishWork.close(workspace, snapshot, 10_000)
    assert :ok = Workspace.close(workspace)
    assert [] = containers(sandbox)
    refute File.exists?(sandbox.root)
    assert_report(snapshot, "Original")
  end

  defp prepare(profile) do
    assert {:ok, workspace} = Workspace.open(profile: profile)
    assert :ok = Workspace.write(workspace, "report.txt", "Original")
    assert {:ok, snapshot} = Workspace.save(workspace)
    {workspace, snapshot}
  end

  defp paused(pid, fun) do
    :ok = :sys.suspend(pid)

    try do
      fun.()
    after
      :ok = :sys.resume(pid)
    end
  end

  defp await_job(controller, kind) do
    await(
      fn -> match?(%{job: %{kind: ^kind}}, :sys.get_state(controller)) end,
      "The controller did not admit the job"
    )
  end

  defp assert_closed_to_work(workspace) do
    assert {:error, %Error{code: :closed}} = Workspace.write(workspace, "report.txt", "Refused")
    assert {:error, %Error{code: :closed}} = Workspace.save(workspace)
    assert {:error, %Error{code: :closed}} = Workspace.run(workspace, ["cat", "report.txt"])
  end

  defp assert_report(snapshot, report) do
    assert {:ok, reopened} = Workspace.open(profile: :memory, from: snapshot)

    try do
      assert {:ok, ^report} = Workspace.read(reopened, "report.txt")
    after
      assert :ok = Workspace.close(reopened)
    end
  end
end
