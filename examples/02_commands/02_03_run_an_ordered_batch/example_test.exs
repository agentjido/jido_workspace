Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.PrepareReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.PrepareReport
  import Jido.Workspace.Examples.LifecycleSupport

  setup %{tmp_dir: root}, do: configure(root)

  test "memory runs the same report steps and keeps the draft after failure" do
    check_report(:memory)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the same batch on Docker"
  end

  test "Docker runs the same report steps and keeps the draft after failure" do
    check_report(:docker)
  end

  test "invalid steps are rejected before the first edit" do
    assert {:ok, workspace} = Workspace.open(profile: :memory)

    for invalid <- [
          {:run, ["cat"], [cwd: "../"]},
          {:run, ["cat"], [timeout_ms: 1, timeout_ms: 2]},
          {:write, "bad.txt", [256]},
          {:mkdir, "."},
          {:save, []}
        ] do
      assert {:error, %Error{code: :invalid_input, operation: :batch, details: %{step_index: 2}}} =
               Workspace.batch(workspace, [{:mkdir, "reports"}, invalid])
    end

    assert {:error, %Error{code: :invalid_input}} =
             Workspace.batch(workspace, List.duplicate({:mkdir, "reports"}, 65))

    assert {:error, %Error{code: :invalid_input}} =
             Workspace.batch(workspace, [{:write, "report.txt", :binary.copy("a", 4_194_304)}])

    assert {:ok, []} = Workspace.list(workspace)
    assert :ok = Workspace.close(workspace)
  end

  test "a command step checks the same access policy as run" do
    put_memory_profile(policy: :workspace_write)
    assert {:ok, workspace} = Workspace.open(profile: :memory)

    assert {:ok,
            %{
              status: :halted,
              results: [:ok],
              failure: %{index: 2, result: %Error{code: :policy_denied, operation: :run}}
            }} =
             Workspace.batch(workspace, [
               {:write, "draft.txt", "Draft"},
               {:run, ["cat", "draft.txt"], []}
             ])

    assert {:ok, "Draft"} = Workspace.read(workspace, "draft.txt")
    assert :ok = Workspace.close(workspace)
  end

  test "an active step blocks other tree work and cancellation halts at its index" do
    assert {:ok, workspace} = Workspace.open(profile: :memory)

    task =
      Task.async(fn ->
        Workspace.batch(workspace, [
          {:write, "draft.txt", "Draft"},
          {:run, ["sleep", "30"], [timeout_ms: 10_000]},
          {:write, "checked.txt", "Checked"}
        ])
      end)

    id = running_id(workspace)
    assert {:error, %Error{code: :busy}} = Workspace.write(workspace, "other.txt", "Other")
    assert {:error, %Error{code: :busy}} = Workspace.run(workspace, ["cat", "draft.txt"])
    assert {:error, %Error{code: :busy}} = Workspace.save(workspace)
    assert {:error, %Error{code: :busy}} = Workspace.batch(workspace, [{:mkdir, "other"}])

    assert :ok = Workspace.cancel(workspace, id)

    assert {:ok,
            %{
              status: :halted,
              results: [:ok],
              failure: %{index: 2, result: %Execution{id: ^id, status: :cancelled}}
            }} = Task.await(task)

    assert {:ok, "Draft"} = Workspace.read(workspace, "draft.txt")
    assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "checked.txt")
    assert {:ok, %{kind: "snapshot"}} = Workspace.save(workspace)
    assert :ok = Workspace.close(workspace)
  end

  test "close lets the active step finish but prevents the next step" do
    assert {:ok, workspace} = Workspace.open(profile: :memory)
    {_controller, memory} = provider(workspace, :memory)
    assert :ok = :sys.suspend(memory.lifetime)

    task =
      Task.async(fn ->
        Workspace.batch(workspace, [
          {:run, ["echo", "Finished"], [timeout_ms: 10_000]},
          {:write, "checked.txt", "Checked"}
        ])
      end)

    try do
      running_id(workspace)

      assert {:error, %Error{code: :cleanup_unconfirmed}} =
               Workspace.close(workspace, timeout_ms: 40)

      await(
        fn -> match?({:ok, %{phase: :closing}}, Workspace.info(workspace)) end,
        "The controller did not accept close"
      )

      assert Task.yield(task, 0) == nil
    after
      :sys.resume(memory.lifetime)
    end

    assert {:ok,
            %{
              status: :halted,
              results: [%Execution{exit_status: 0, output: "Finished\n"}],
              failure: %{index: 2, result: %Error{code: :closed, operation: :write}}
            }} = Task.await(task)

    assert :ok = Workspace.close(workspace)
  end

  test "an unconfirmed stop halts the batch and fences the tree" do
    assert {:ok, workspace} = Workspace.open(profile: :memory)
    {_controller, memory} = provider(workspace, :memory)
    assert :ok = :sys.suspend(memory.lifetime)

    try do
      task =
        Task.async(fn ->
          Workspace.batch(workspace, [
            {:run, ["echo", "Still blocked"], [timeout_ms: 10_000]},
            {:mkdir, "checked"}
          ])
        end)

      id = running_id(workspace)
      assert :ok = Workspace.cancel(workspace, id)

      assert {:ok,
              %{
                status: :halted,
                results: [],
                failure: %{
                  index: 1,
                  result: %Error{code: :quiescence_unknown, details: %{execution_id: ^id}}
                }
              }} = Task.await(task)

      assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)
      assert {:error, %Error{code: :quiescence_unknown}} = Workspace.mkdir(workspace, "other")
    after
      :sys.resume(memory.lifetime)
    end

    assert :ok = Workspace.close(workspace)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check a lost provider during an edit"
  end

  test "a lost Docker controller halts an unconfirmed file step and fences the tree" do
    assert {:ok, workspace} = Workspace.open(profile: :docker)
    {_controller, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)
    assert :ok = :sys.suspend(sandbox.pid)

    task =
      Task.async(fn ->
        Workspace.batch(workspace, [
          {:write, "draft.txt", "Draft"},
          {:mkdir, "checked"}
        ])
      end)

    await(
      fn -> match?({:ok, %{phase: :batching}}, Workspace.info(workspace)) end,
      "The controller did not admit the edit"
    )

    assert Process.exit(sandbox.pid, :kill)

    assert {:ok,
            %{
              status: :halted,
              results: [],
              failure: %{index: 1, result: %Error{operation: :write, code: :quiescence_unknown}}
            }} = Task.await(task)

    assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)
    assert {:error, %Error{code: :cleanup_unconfirmed}} = Workspace.close(workspace)
  end

  test "the memory profile bounds the total returned command output" do
    check_output_budget(:memory)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the output cap on Docker"
  end

  test "the Docker profile bounds the total returned command output" do
    check_output_budget(:docker)
  end

  test "the batch deadline caps the active command time" do
    put_memory_profile(limits: %{batch_timeout_ms: 1_500})
    assert {:ok, workspace} = Workspace.open(profile: :memory)

    assert {:ok,
            %{
              status: :halted,
              results: [:ok],
              failure: %{index: 2, result: %Execution{status: :timed_out}}
            }} =
             Workspace.batch(workspace, [
               {:write, "draft.txt", "Draft"},
               {:run, ["sleep", "30"], [timeout_ms: 15_000]},
               {:write, "checked.txt", "Checked"}
             ])

    assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "checked.txt")
    assert :ok = Workspace.close(workspace)
  end

  defp check_output_budget(profile) do
    put_profile(profile, limits: %{batch_output_limit: 8})
    assert {:ok, workspace} = Workspace.open(profile: profile)

    try do
      assert {:ok,
              %{
                status: :completed,
                results: [
                  %Execution{output: "draft\n", truncated: false},
                  %Execution{output: "dr", truncated: true},
                  %Execution{output: "", truncated: true}
                ]
              }} = Workspace.batch(workspace, List.duplicate({:run, ["echo", "draft"], []}, 3))

      assert {:ok, %Execution{output: "draft\n"}} = Workspace.run(workspace, ["echo", "draft"])
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp check_report(profile) do
    assert {:ok, workspace} = Workspace.open(profile: profile)

    try do
      assert {:ok,
              %{
                status: :halted,
                results: [:ok, :ok],
                failure: %{index: 3, result: %Execution{status: :exited, exit_status: 1} = result}
              }} = PrepareReport.prepare(workspace, ["missing.txt"])

      assert String.contains?(result.output, "Sales report\n")
      assert String.contains?(result.output, "missing.txt")
      assert {:ok, "Sales report\n"} = Workspace.read(workspace, "reports/draft.txt")
      assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "reports/checked.txt")
    after
      assert :ok = Workspace.close(workspace)
    end

    assert {:ok, workspace} = Workspace.open(profile: profile)

    snapshot =
      try do
        assert {:ok, %{kind: "snapshot"} = snapshot} =
                 PrepareReport.prepare(workspace)

        snapshot
      after
        assert :ok = Workspace.close(workspace)
      end

    assert {:ok, reopened} = Workspace.open(profile: profile, from: snapshot)
    assert {:ok, "Inputs checked\n"} = Workspace.read(reopened, "reports/checked.txt")
    assert :ok = Workspace.close(reopened)
  end

  defp put_memory_profile(attrs), do: put_profile(:memory, attrs)

  defp put_profile(name, attrs) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    updated = Map.update!(profiles, name, &Map.merge(&1, Map.new(attrs)))
    Application.put_env(:jido_workspace, :profiles, updated)
  end

  defp running_id(workspace) do
    await(
      fn ->
        case Workspace.info(workspace) do
          {:ok, %{phase: :running, active_execution_id: id}} -> id
          _ -> nil
        end
      end,
      "The batch command did not start"
    )
  end
end
