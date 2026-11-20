Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.BuildAndReviewTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.{BuildAndReview, LifecycleSupport}

  @draft "app/draft; Q4.txt"
  @expected "app/expected.txt"
  @product "app/report.txt"
  @report "REPORT\nQUARTERLY REPORT\n"

  setup %{tmp_dir: root} do
    store = Path.join(root, "snapshots")
    LifecycleSupport.configure(store)
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    policy = [:read, :write, :execute, :save]

    Application.put_env(
      :jido_workspace,
      :profiles,
      Map.merge(profiles, %{
        lua_build: Map.merge(profiles.memory, %{policy: policy, tools: ["lua"]}),
        docker_build: Map.merge(profiles.docker, %{policy: policy, tools: ["sh"]}),
        reviewer: %{profiles.memory | policy: :read_only}
      })
    )

    %{store: store}
  end

  test "memory publishes only passing builds, including a corrected retry", %{store: store} do
    verify_retry(:lua_build, "lua", "report.lua", store)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check success and failure on Docker"
  end

  test "Docker publishes only passing builds, including a corrected retry", %{store: store} do
    verify_retry(:docker_build, "sh", "report.sh", store)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the native build and live test checkpoint"
  end

  test "Docker shows live test output before the host admits the handoff", %{store: store} do
    workspace = prepare(:docker_build, "report.sh")
    {build, {argv, opts}} = steps("sh", "report.sh")
    output = forward_to(self())

    task =
      Task.async(fn ->
        test = {argv ++ ["wait"], Keyword.put(opts, :stdin, :pipe)}
        BuildAndReview.run(workspace, build, test, output)
      end)

    assert stage_output(:build) == "building report\n"
    id = wait_for_test_output("testing report\n")
    assert File.ls(store) in [{:error, :enoent}, {:ok, []}]
    assert {:error, %Error{code: :busy}} = Workspace.save(workspace)
    assert :ok = Workspace.input(workspace, id, "continue\n")

    assert {:ok, snapshot} = Task.await(task, 10_000)
    assert stage_output(:test) == "passed\n"
    assert :ok = Workspace.close(workspace)
    verify_handoff(snapshot, @report)
  end

  test "a command rejected before admission stops the workflow without a start notice", %{
    store: store
  } do
    workspace = prepare(:lua_build, "report.lua")
    {_, test} = steps("lua", "report.lua")
    tag = make_ref()
    denied = {["sh", "report.lua"], [cwd: "app"]}

    assert {:error, %{stage: :build, reason: %Error{code: :policy_denied}}} =
             BuildAndReview.run(workspace, denied, test, forward_to(self()))

    assert {:error, %Error{code: :policy_denied}} =
             Workspace.run(workspace, ["sh", "report.lua"], notify_start: {self(), tag})

    refute_received {:workspace_command_started, ^tag, _}
    refute_received {:progress, _, _, _}
    assert File.ls(store) in [{:error, :enoent}, {:ok, []}]
    assert :ok = Workspace.close(workspace)
  end

  test "batch steps send distinct start notices, including commands that have already exited" do
    assert {:ok, workspace} = Workspace.open(profile: :memory)
    first = make_ref()
    second = make_ref()

    assert {:error, %Error{code: :invalid_input}} =
             Workspace.run(workspace, ["echo", "invalid"],
               notify_start: {self(), "not a reference"}
             )

    assert {:ok, %{status: :completed, results: [%Execution{id: one}, %Execution{id: two}]}} =
             Workspace.batch(workspace, [
               {:run, ["echo", "first"], [notify_start: {self(), first}]},
               {:run, ["echo", "second"], [notify_start: {self(), second}]}
             ])

    assert_receive {:workspace_command_started, ^first, ^one}
    assert_receive {:workspace_command_started, ^second, ^two}
    assert one != two
    assert {:error, %Error{code: :output_unavailable}} = Workspace.output(workspace, one)
    assert {:ok, %{bytes: "second\n", done?: true}} = Workspace.output(workspace, two)
    assert :ok = Workspace.close(workspace)
  end

  defp verify_retry(profile, tool, script, store) do
    workspace = prepare(profile, script)
    {build, test} = steps(tool, script)
    output = forward_to(self())

    assert {:ok, first} = BuildAndReview.run(workspace, build, test, output)
    assert stage_output(:build) == "building report\n"
    assert stage_output(:test) == "testing report\npassed\n"
    assert [first.digest] == File.ls!(store)

    revised = "REPORT\nREVISED REPORT\n"
    assert :ok = Workspace.write(workspace, @draft, "revised report\n")

    assert {:error, %{stage: :test, reason: %Execution{status: :exited, exit_status: 1}}} =
             BuildAndReview.run(workspace, build, test, output)

    assert stage_output(:build) == "building report\n"
    assert stage_output(:test) =~ "built report differs from expected"
    assert {:ok, ^revised} = Workspace.read(workspace, @product)
    assert [first.digest] == File.ls!(store)

    assert :ok = Workspace.write(workspace, @expected, revised)
    assert {:ok, second} = BuildAndReview.run(workspace, build, test, output)
    assert first.digest != second.digest
    assert :ok = Workspace.close(workspace)

    verify_handoff(first, @report)
    verify_handoff(second, revised)
  end

  defp prepare(profile, script) do
    assert {:ok, workspace} = Workspace.open(profile: profile)
    assert :ok = Workspace.mkdir(workspace, "app")
    assert :ok = Workspace.write(workspace, @draft, "quarterly report\n")
    assert :ok = Workspace.write(workspace, @expected, @report)

    assert :ok =
             Workspace.write(workspace, "app/" <> script, File.read!(Path.join(__DIR__, script)))

    workspace
  end

  defp steps(tool, script) do
    opts = [cwd: "app", output_limit: 4_096]
    build = {[tool, script, "build", Path.basename(@draft), "report.txt"], opts}
    test = {[tool, script, "test", "expected.txt", "report.txt"], opts}
    {build, test}
  end

  defp forward_to(pid), do: fn stage, id, slice -> send(pid, {:progress, stage, id, slice}) end

  defp stage_output(stage, output \\ "") do
    assert_receive {:progress, ^stage, _id, %{bytes: bytes, dropped_bytes: 0, done?: done?}},
                   10_000

    if done?, do: output <> bytes, else: stage_output(stage, output <> bytes)
  end

  defp wait_for_test_output(expected, output \\ "") do
    assert_receive {:progress, :test, id, %{bytes: bytes, dropped_bytes: 0, done?: false}}, 10_000
    output = output <> bytes
    if output == expected, do: id, else: wait_for_test_output(expected, output)
  end

  defp verify_handoff(snapshot, report) do
    json = Jason.encode!(snapshot)

    Task.async(fn ->
      assert {:ok, workspace} = Workspace.open(profile: :reviewer, from: Jason.decode!(json))

      try do
        assert {:ok, ^report} = Workspace.read(workspace, @product)

        assert {:error, %Error{code: :policy_denied}} =
                 Workspace.write(workspace, @product, "edit")

        assert {:error, %Error{code: :policy_denied}} = Workspace.save(workspace)
      after
        assert :ok = Workspace.close(workspace)
      end
    end)
    |> Task.await(10_000)
  end
end
