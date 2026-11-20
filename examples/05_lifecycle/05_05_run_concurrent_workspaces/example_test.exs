Code.require_file("../support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.ConcurrentReportsTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.ConcurrentReports
  import Jido.Workspace.Examples.LifecycleSupport

  setup %{tmp_dir: root} do
    configure(root)
    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    profiles =
      Map.merge(profiles, %{
        memory_short: Map.put(profiles.memory, :limits, %{output_limit: 5}),
        memory_wide: Map.put(profiles.memory, :limits, %{output_limit: 8}),
        memory_deadline: Map.put(profiles.memory, :limits, %{timeout_ms: 100}),
        docker_short: Map.put(profiles.docker, :limits, %{output_limit: 5}),
        docker_wide: Map.put(profiles.docker, :limits, %{output_limit: 8}),
        docker_deadline: Map.put(profiles.docker, :limits, %{timeout_ms: 1_000})
      })

    Application.put_env(:jido_workspace, :profiles, profiles)
    %{owners: start_supervised!(Task.Supervisor)}
  end

  test "memory commands overlap and closing the first tree leaves the second tree in use",
       %{owners: owners} do
    exercise_pair(owners, :memory_short, :memory_wide, &hold_memory_read/1)
  end

  test "the memory profile deadline caps a caller's longer timeout", %{owners: owners} do
    workspace = open(owners, :memory_deadline, "Report")
    {_controller, memory} = provider(workspace, :memory)
    resume = suspend(memory.lifetime)

    try do
      task = ConcurrentReports.read(workspace, timeout_ms: 30_000)
      assert {:error, %Error{code: :quiescence_unknown}} = Task.await(task, 2_000)
      assert {:ok, %{phase: :quiescence_unknown}} = Workspace.info(workspace)
      assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)
    after
      resume.()
    end

    assert :ok = Workspace.close(workspace)
  end

  test "invalid host limits fail profile admission" do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    for limits <- [%{timeout_ms: 0}, %{output_limit: -1}, %{output_bytes: 10}] do
      invalid = Map.put(profiles.memory, :limits, limits)
      Application.put_env(:jido_workspace, :profiles, Map.put(profiles, :invalid, invalid))
      assert {:error, %Error{code: :invalid_profile}} = Workspace.open(profile: :invalid)
    end
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to verify two live containers"
  end

  test "two Docker commands overlap and closing one root leaves the other container in use",
       %{owners: owners} do
    exercise_pair(owners, :docker_short, :docker_wide, &hold_docker_read/1)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to verify the Docker profile deadline"
  end

  test "the Docker profile deadline stops the command and permits a save", %{owners: owners} do
    workspace = open(owners, :docker_deadline, "Report")
    {_controller, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)

    task = Task.async(fn -> Workspace.run(workspace, ["sleep", "60"], timeout_ms: 30_000) end)
    assert {:ok, %Execution{status: :timed_out, exit_status: nil}} = Task.await(task, 10_000)
    assert [] = containers(sandbox, ["--filter", "status=running"])
    assert {:ok, %{kind: "snapshot"}} = Workspace.save(workspace)
    assert :ok = Workspace.close(workspace)
  end

  defp exercise_pair(owners, first_profile, second_profile, hold_read) do
    first = open(owners, first_profile, "alpha-message")
    second = open(owners, second_profile, "beta-message")
    assert {:ok, %{owner: first_owner}} = Workspace.info(first)
    assert {:ok, %{owner: second_owner}} = Workspace.info(second)
    assert first_owner != second_owner
    assert first.id != second.id
    assert {:ok, "alpha-message"} = Workspace.read(first, "report.txt")
    assert {:ok, "beta-message"} = Workspace.read(second, "report.txt")

    {first_task, finish_first, first_released?} = hold_read.(first)
    {second_task, finish_second, second_released?} = hold_read.(second)
    first_execution = running_id(first)
    second_execution = running_id(second)
    assert first_execution != second_execution
    assert {:error, %Error{code: :busy}} = Workspace.save(first)
    assert {:error, %Error{code: :busy}} = Workspace.save(second)

    finish_first.()

    assert {:ok, %Execution{id: ^first_execution, output: "alpha", truncated: true}} =
             Task.await(first_task, 10_000)

    assert {:ok, first_snapshot} = Workspace.save(first)
    assert :ok = Workspace.close(first)
    assert {:error, %Error{code: :closed}} = Workspace.read(first, "report.txt")
    assert first_released?.()
    assert ^second_execution = running_id(second)

    finish_second.()

    assert {:ok, %Execution{id: ^second_execution, output: "beta-mes", truncated: true}} =
             Task.await(second_task, 10_000)

    assert :ok = Workspace.write(second, "report.txt", "Second survived")
    smaller_read = ConcurrentReports.read(second, output_limit: 3)
    assert {:ok, %Execution{output: "Sec", truncated: true}} = Task.await(smaller_read, 10_000)
    assert {:ok, second_snapshot} = Workspace.save(second)
    assert :ok = Workspace.close(second)
    assert second_released?.()

    assert_snapshot(first_profile, first_snapshot, "alpha-message")
    assert_snapshot(second_profile, second_snapshot, "Second survived")
  end

  defp open(owners, profile, report) do
    {:ok, owner} =
      Task.Supervisor.start_child(owners, fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, workspace} = Workspace.open(profile: profile, owner: owner)
    assert :ok = Workspace.write(workspace, "report.txt", report)
    workspace
  end

  defp running_id(workspace) do
    await(
      fn ->
        case Workspace.info(workspace) do
          {:ok, %{phase: :running, active_execution_id: id}} -> id
          _ -> nil
        end
      end,
      "The workspace did not report an active command"
    )
  end

  defp hold_memory_read(workspace) do
    {_controller, memory} = provider(workspace, :memory)
    resume = suspend(memory.lifetime)
    task = ConcurrentReports.read(workspace, output_limit: 100)
    {task, resume, fn -> Jido.Shell.VFS.list_mounts(memory.id) == [] end}
  end

  defp hold_docker_read(workspace) do
    {_controller, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)

    task =
      Task.async(fn ->
        Workspace.run(
          workspace,
          ["sh", "-c", ~S(mkfifo /tmp/finish && read -r line </tmp/finish && cat report.txt)],
          output_limit: 100
        )
      end)

    container = await(fn -> container_running(sandbox) end, "No running container", 10_000)

    await(
      fn -> match?({_, 0}, docker(["exec", container, "test", "-p", "/tmp/finish"])) end,
      "The command did not create its pipe",
      5_000
    )

    finish = fn ->
      assert {_, 0} = docker(["exec", container, "sh", "-c", ~S(printf 'go\n' >/tmp/finish)])
    end

    {task, finish, fn -> not File.exists?(sandbox.root) and containers(sandbox) == [] end}
  end

  defp suspend(pid) do
    assert :ok = :sys.suspend(pid)
    on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)
    fn -> assert :ok = :sys.resume(pid) end
  end

  defp assert_snapshot(profile, snapshot, report) do
    assert {:ok, workspace} = Workspace.open(profile: profile, from: snapshot)

    try do
      assert {:ok, ^report} = Workspace.read(workspace, "report.txt")
    after
      assert :ok = Workspace.close(workspace)
    end
  end
end
