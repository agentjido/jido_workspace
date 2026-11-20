Code.require_file("../support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.ObserveCommandTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution, Info}
  alias Jido.Workspace.Examples.ObserveCommand
  import Jido.Workspace.Examples.LifecycleSupport

  setup %{tmp_dir: root} do
    configure(root)

    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    Application.put_env(
      :jido_workspace,
      :profiles,
      Map.merge(profiles, %{
        memory_reader: %{profiles.memory | policy: :read_only},
        docker_reader: %{profiles.docker | policy: :read_only}
      })
    )

    :ok
  end

  test "the active ID identifies both the memory command result and its stop event" do
    workspace = open(:memory)
    assert :ok = Workspace.write(workspace, "report.txt", "Saved report")
    {_controller, memory} = provider(workspace, :memory)
    subscribe(workspace)
    assert :ok = :sys.suspend(memory.lifetime)

    {task, id} =
      try do
        task =
          Task.async(fn -> Workspace.run(workspace, ["cat", "report.txt"], output_limit: 5) end)

        id = active_command(workspace)
        {task, id}
      after
        :sys.resume(memory.lifetime)
      end

    assert {:ok, %Execution{id: ^id, status: :exited, exit_status: 0} = result} = Task.await(task)
    assert result.output == "Saved"
    assert result.truncated
    assert_stop(workspace, result)
    assert_ready(workspace)
    assert_admitted_failure(workspace)
    assert_closed(workspace)
  end

  test "a read-only memory workspace exposes status and refuses writes and commands" do
    assert_read_only(:memory_reader)
  end

  test "status remains available when a lost worker fences writes" do
    workspace = open(:memory)
    {controller, memory} = provider(workspace, :memory)
    subscribe(workspace)
    assert :ok = :sys.suspend(memory.lifetime)

    try do
      task = Task.async(fn -> Workspace.run(workspace, ["cat", "report.txt"]) end)
      id = active_command(workspace)
      assert %{job: %{task: %{pid: worker}}} = :sys.get_state(controller)
      assert Process.exit(worker, :kill)

      assert {:error, %Error{code: :quiescence_unknown, details: %{execution_id: ^id}}} =
               Task.await(task)

      assert_error_event(workspace, id, :quiescence_unknown)

      assert {:ok, %Info{phase: :quiescence_unknown, active_execution_id: nil}} =
               Workspace.info(workspace)

      assert {:error, %Error{code: :quiescence_unknown}} =
               Workspace.write(workspace, "report.txt", "Blocked")

      assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)
    after
      :sys.resume(memory.lifetime)
    end

    assert_closed(workspace)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to observe a live Docker command"
  end

  test "a Docker command returns bounded output and the same ID on a nonzero exit" do
    workspace = open(:docker)
    {_controller, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)
    subscribe(workspace)

    task =
      Task.async(fn ->
        Workspace.run(
          workspace,
          [
            "sh",
            "-c",
            ~S(mkfifo /tmp/finish && read -r line </tmp/finish && printf '%s' "$1"; exit 7),
            "fixture",
            "private output"
          ],
          output_limit: 7,
          timeout_ms: 20_000
        )
      end)

    id = active_command(workspace)
    container = await(fn -> container_running(sandbox) end, "No running container", 10_000)

    await(
      fn -> match?({_, 0}, docker(["exec", container, "test", "-p", "/tmp/finish"])) end,
      "The command did not create its pipe",
      5_000
    )

    assert {_, 0} = docker(["exec", container, "sh", "-c", ~S(printf 'go\n' >/tmp/finish)])

    assert {:ok, %Execution{id: ^id, status: :exited, exit_status: 7} = result} =
             Task.await(task, 10_000)

    assert result.output == "private"
    assert result.truncated
    assert_stop(workspace, result)
    assert_ready(workspace)
    assert_admitted_failure(workspace)
    assert_closed(workspace)
    assert [] = containers(sandbox)
    refute File.exists?(sandbox.root)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check read-only Docker status"
  end

  test "a read-only Docker workspace exposes status and refuses writes and commands" do
    assert_read_only(:docker_reader)
  end

  defp open(profile) do
    assert {:ok, workspace} = Workspace.open(profile: profile)
    assert_ready(workspace)
    workspace
  end

  defp subscribe(workspace) do
    assert {:ok, handler} = ObserveCommand.attach(workspace)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp active_command(workspace) do
    id = assert_start(workspace)
    assert {:ok, %Info{phase: :running, active_execution_id: ^id}} = Workspace.info(workspace)
    id
  end

  defp assert_start(%{id: workspace_id}) do
    assert_receive {:workspace_command, :start, %{system_time: system_time}, data}, 2_000
    assert is_integer(system_time)
    assert %{workspace_id: ^workspace_id, execution_id: id} = data
    assert data == %{workspace_id: workspace_id, execution_id: id}
    id
  end

  defp assert_stop(%{id: workspace_id}, result) do
    assert_receive {:workspace_command, :stop, %{duration_ms: duration}, data}, 2_000
    assert duration == result.duration_ms

    assert data == %{
             workspace_id: workspace_id,
             execution_id: result.id,
             status: :exited,
             exit_status: result.exit_status
           }
  end

  defp assert_admitted_failure(workspace) do
    assert {:error, %Error{code: :not_found, operation: :run, details: details}} =
             Workspace.run(workspace, ["cat", "report.txt"], cwd: "missing-directory")

    id = assert_start(workspace)
    assert %{execution_id: ^id} = details
    assert_error_event(workspace, id, :not_found)
    assert_ready(workspace)
  end

  defp assert_error_event(workspace, id, code) do
    assert_receive {:workspace_command, :stop, %{duration_ms: duration}, data}
    assert duration >= 0

    assert data == %{
             workspace_id: workspace.id,
             execution_id: id,
             status: :error,
             error_code: code
           }
  end

  defp assert_read_only(profile) do
    workspace = open(profile)
    subscribe(workspace)
    assert {:ok, %Info{policy: :read_only, phase: :ready}} = Workspace.info(workspace)
    assert {:error, %Error{code: :policy_denied}} = Workspace.write(workspace, "report.txt", "X")

    assert {:error, %Error{code: :policy_denied}} =
             Workspace.run(workspace, ["cat", "report.txt"])

    refute_received {:workspace_command, _, _, _}
    assert_closed(workspace)
  end

  defp assert_ready(workspace) do
    assert {:ok, %Info{phase: :ready, active_execution_id: nil}} = Workspace.info(workspace)
  end

  defp assert_closed(workspace) do
    assert :ok = Workspace.close(workspace)
    assert {:error, %Error{code: :closed}} = Workspace.info(workspace)
  end
end
