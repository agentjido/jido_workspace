Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.StopCommandTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.StopCommand
  import Jido.Workspace.Examples.LifecycleSupport

  setup %{tmp_dir: root}, do: configure(root)

  test "memory cancels at a tool checkpoint and keeps bounded output" do
    workspace = open(:memory)
    task = start_memory_command(workspace, 30_000)
    {id, worker} = memory_with_output(workspace)

    assert :erlang.suspend_process(worker)

    try do
      assert {:error, %Error{code: :execution_not_active}} = Workspace.cancel(workspace, "old")
      assert {:pending, ^task} = StopCommand.cancel_and_wait(workspace, id, task, 0)
      assert {:error, %Error{code: :busy}} = Workspace.save(workspace)
    after
      :erlang.resume_process(worker)
    end

    assert {:ok,
            %Execution{
              id: ^id,
              status: :cancelled,
              exit_status: nil,
              output: "Sleeping",
              truncated: true
            }} = Task.await(task)

    assert {:error, %Error{code: :execution_not_active}} = Workspace.cancel(workspace, id)
    assert_ready_for_save(workspace)
    assert :ok = Workspace.close(workspace)
  end

  test "memory confirms a timeout at a tool checkpoint and keeps bounded output" do
    workspace = open(:memory)
    task = start_memory_command(workspace, 1_800)
    {id, _worker} = memory_with_output(workspace)

    assert {:ok,
            %Execution{
              id: ^id,
              status: :timed_out,
              exit_status: nil,
              output: "Sleeping",
              truncated: true
            }} = Task.await(task)

    assert_ready_for_save(workspace)
    assert :ok = Workspace.close(workspace)
  end

  test "a memory worker blocked outside its checkpoint leaves the tree fenced" do
    workspace = open(:memory)
    {_controller, memory} = provider(workspace, :memory)
    assert :ok = :sys.suspend(memory.lifetime)

    try do
      task = start_memory_command(workspace, 30_000)
      id = running_id(workspace)
      assert :ok = Workspace.cancel(workspace, id)

      assert {:error, %Error{code: :quiescence_unknown, details: %{execution_id: ^id}}} =
               Task.await(task)

      assert_fenced(workspace)
    after
      :sys.resume(memory.lifetime)
    end

    assert_fenced(workspace)
    assert :ok = Workspace.close(workspace)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to confirm native cancellation"
  end

  test "Docker cancellation removes the child writer and keeps bounded output" do
    {workspace, sandbox, task, id, _container} = start_docker_writer(30_000)
    assert :ok = :sys.suspend(sandbox.pid)

    try do
      assert {:pending, ^task} = StopCommand.cancel_and_wait(workspace, id, task, 0)
      assert {:error, %Error{code: :busy}} = Workspace.save(workspace)
    after
      :sys.resume(sandbox.pid)
    end

    assert_stopped_writer(workspace, sandbox, task, id, :cancelled)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to confirm native timeout"
  end

  test "Docker timeout removes the child writer and keeps bounded output" do
    {workspace, sandbox, task, id, _container} = start_docker_writer(3_000)
    assert_stopped_writer(workspace, sandbox, task, id, :timed_out)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to exercise a lost provider during stop"
  end

  test "a lost Docker controller leaves a live child and fences writes" do
    {workspace, sandbox, task, id, container} = start_docker_writer(30_000)
    assert :ok = :sys.suspend(sandbox.pid)
    assert :ok = Workspace.cancel(workspace, id)
    assert Process.exit(sandbox.pid, :kill)

    assert {:error, %Error{code: :quiescence_unknown, details: %{execution_id: ^id}}} =
             Task.await(task)

    assert {:ok, %{bytes: "6789", next_offset: 10, dropped_bytes: 6, done?: true}} =
             Workspace.output(workspace, id)

    assert ^container = container_running(sandbox)
    assert_fenced(workspace)
    assert {:error, %Error{code: :cleanup_unconfirmed}} = Workspace.close(workspace)
  end

  defp open(profile) do
    assert {:ok, workspace} = Workspace.open(profile: profile)
    workspace
  end

  defp start_memory_command(workspace, timeout) do
    Task.async(fn ->
      Workspace.run(workspace, ["sleep", "30"], timeout_ms: timeout, output_limit: 8)
    end)
  end

  defp memory_with_output(workspace) do
    id = running_id(workspace)
    {controller, _memory} = provider(workspace, :memory)
    assert %{job: %{task: %{pid: worker}}} = :sys.get_state(controller)

    await(
      fn ->
        match?(
          {:ok, %{next_offset: offset, done?: false}} when offset > 8,
          Workspace.output(workspace, id)
        )
      end,
      "The virtual command did not capture output"
    )

    {id, worker}
  end

  defp running_id(workspace) do
    await(
      fn ->
        case Workspace.info(workspace) do
          {:ok, %{phase: :running, active_execution_id: id}} -> id
          _ -> nil
        end
      end,
      "The command did not reach the running phase"
    )
  end

  defp start_docker_writer(timeout) do
    workspace = open(:docker)
    {_controller, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)

    script = """
    mkfifo /tmp/child-finish
    (
      printf child > started.txt
      printf 0123456789
      read -r line </tmp/child-finish && printf late > late.txt
    ) &
    wait
    """

    task =
      Task.async(fn ->
        Workspace.run(workspace, ["sh", "-c", script], timeout_ms: timeout, output_limit: 4)
      end)

    id = running_id(workspace)
    container = await(fn -> container_running(sandbox) end, "No running container", 10_000)

    await(
      fn ->
        match?(
          {:ok, %{bytes: "6789", next_offset: 10, dropped_bytes: 6, done?: false}},
          Workspace.output(workspace, id)
        )
      end,
      "The child did not write its first bytes"
    )

    {workspace, sandbox, task, id, container}
  end

  defp assert_stopped_writer(workspace, sandbox, task, id, status) do
    assert {:ok,
            %Execution{
              id: ^id,
              status: ^status,
              exit_status: nil,
              output: "0123",
              truncated: true
            }} = Task.await(task, 10_000)

    assert [] = containers(sandbox)
    assert {:ok, "child"} = Workspace.read(workspace, "started.txt")
    assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "late.txt")
    assert_ready_for_save(workspace)
    assert :ok = Workspace.close(workspace)
  end

  defp assert_ready_for_save(workspace) do
    assert {:ok, %{phase: :ready, active_execution_id: nil}} = Workspace.info(workspace)
    assert :ok = Workspace.write(workspace, "review.txt", "Reviewed")
    assert {:ok, %{kind: "snapshot"}} = Workspace.save(workspace)
  end

  defp assert_fenced(workspace) do
    assert {:ok, %{phase: :quiescence_unknown}} = Workspace.info(workspace)
    assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)

    assert {:error, %Error{code: :quiescence_unknown}} =
             Workspace.write(workspace, "review.txt", "Blocked")
  end
end
