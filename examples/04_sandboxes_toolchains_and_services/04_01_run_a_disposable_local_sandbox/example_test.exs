Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.DisposableSandboxTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution, Sandbox}
  alias Jido.Workspace.Examples.DisposableSandbox
  import Jido.Workspace.Examples.LifecycleSupport

  @report "Checked report\n"

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))
    missing = Path.expand(Path.join(root, "missing-tool"))

    put_profile(:local, %{
      provider: :local,
      policy: :full_access,
      tools: ["/bin/cat", "/bin/cp", "/bin/sleep", missing],
      require: %{isolation: :process},
      store: "reports"
    })

    %{missing: missing}
  end

  test "Local runs an approved executable, saves its file, and removes the owned root" do
    exercise_disposable(:local, :process)
  end

  test "a missing native executable returns a start failure and the tree stays available", %{
    missing: missing
  } do
    assert {:ok, workspace} = Workspace.open(profile: :local)

    try do
      assert {:error, %Error{operation: :run, code: :policy_denied}} =
               Workspace.run(workspace, ["/bin/sh"])

      assert {:error, %Error{operation: :run, code: :start_failed}} =
               Workspace.run(workspace, [missing])

      assert {:error, %Error{operation: :run, code: :unsupported_capability}} =
               Workspace.run(workspace, ["/bin/sleep", "1"], stdin: :pipe)

      assert {:ok, %Execution{status: :exited, exit_status: 0, output: ""}} =
               Workspace.run(workspace, ["/bin/cat"], stdin: :closed, timeout_ms: 1_000)

      assert {:ok, %{phase: :ready}} = Workspace.info(workspace)
      assert {:ok, _} = DisposableSandbox.copy_report(workspace, @report)
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  test "Local admission refuses an unsafe profile and unmet isolation" do
    profile = Application.fetch_env!(:jido_workspace, :profiles).local

    for changes <- [
          %{policy: [:read, :execute]},
          %{tools: []},
          %{tools: ["cp"]},
          %{checkout: System.tmp_dir!()},
          %{image: "alpine:3.20"}
        ] do
      put_profile(:invalid, Map.merge(profile, changes))
      assert {:error, %Error{code: :invalid_profile}} = Workspace.open(profile: :invalid)
    end

    put_profile(:isolated, %{profile | require: %{isolation: :container}})

    assert {:error, %Error{code: :unsupported_capability, details: %{capability: :isolation}}} =
             Workspace.open(profile: :isolated)

    put_profile(:offline, %{profile | require: %{network: :disabled}})

    assert {:error, %Error{code: :unsupported_capability, details: %{capability: :network}}} =
             Workspace.open(profile: :offline)
  end

  test "a timeout waits for the direct Local process to exit" do
    assert {:ok, workspace} = Workspace.open(profile: :local)
    {_controller, sandbox} = provider(workspace, :native)

    try do
      assert %{cancellation: :direct_child} = Sandbox.capabilities(sandbox)

      task =
        Task.async(fn ->
          Workspace.run(workspace, ["/bin/sleep", "30"], timeout_ms: 2_000)
        end)

      %{os_pid: pid} = running_process(sandbox)

      assert {"", 0} = probe_pid(pid)
      assert {:error, %Error{code: :busy}} = Workspace.save(workspace)

      assert {:ok, %Execution{status: :timed_out, exit_status: nil}} =
               Task.await(task, 5_000)

      assert {_, status} = probe_pid(pid)
      assert status != 0
      assert {:ok, _} = DisposableSandbox.copy_report(workspace, @report)
    after
      assert :ok = Workspace.close(workspace)
    end

    refute File.exists?(sandbox.root)
  end

  test "losing the Local command port leaves a live process and fences the tree" do
    assert {:ok, workspace} = Workspace.open(profile: :local)
    {_controller, sandbox} = provider(workspace, :native)
    task = Task.async(fn -> Workspace.run(workspace, ["/bin/sleep", "30"]) end)
    %{handle: port, os_pid: pid} = running_process(sandbox)

    try do
      assert {"", 0} = probe_pid(pid)
      assert true == Port.close(port)

      assert {:error, %Error{code: :quiescence_unknown}} = Task.await(task)
      assert {"", 0} = probe_pid(pid)
      assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)

      assert {:error, %Error{code: :quiescence_unknown}} =
               Workspace.write(workspace, "late.txt", "Blocked")

      assert {:error, %Error{code: :cleanup_unconfirmed}} = Workspace.close(workspace)
      assert File.dir?(sandbox.root)
    after
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      await(
        fn -> match?({_, code} when code != 0, probe_pid(pid)) end,
        "The test fixture process did not exit"
      )

      DynamicSupervisor.terminate_child(Sandbox.Supervisor, sandbox.pid)
      File.rm_rf!(sandbox.root)
    end
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to compare native cleanup on Docker"
  end

  test "Docker runs the same report and removes the container and owned root" do
    exercise_disposable(:docker, :container)
  end

  defp exercise_disposable(profile, isolation) do
    assert {:ok, workspace} = Workspace.open(profile: profile)
    {_controller, sandbox} = provider(workspace, :native)
    closed = Process.monitor(sandbox.pid)
    if profile == :docker, do: clean_up_docker_on_failure(sandbox)

    snapshot =
      try do
        assert {:ok, %{capabilities: %{provider: ^profile, isolation: ^isolation}}} =
                 Workspace.info(workspace)

        assert {:ok, snapshot} = DisposableSandbox.copy_report(workspace, @report)
        assert :ok = Workspace.write(workspace, "report.txt", "Unsaved change")
        assert File.dir?(sandbox.root)
        if profile == :docker, do: assert([_] = containers(sandbox))
        snapshot
      after
        assert :ok = Workspace.close(workspace)
      end

    assert_receive {:DOWN, ^closed, :process, _, :normal}
    refute File.exists?(sandbox.root)
    assert {:error, :not_found} = Sandbox.attach(sandbox.id)
    assert {:error, %Error{code: :closed}} = Workspace.read(workspace, "report.txt")
    assert :ok = Workspace.close(workspace)
    if profile == :docker, do: assert([] = containers(sandbox))

    assert {:ok, restored} = Workspace.open(profile: :memory, from: snapshot)

    try do
      assert {:ok, @report} = Workspace.read(restored, "report.txt")
    after
      assert :ok = Workspace.close(restored)
    end
  end

  defp probe_pid(pid),
    do: System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

  defp running_process(sandbox) do
    await(
      fn ->
        {:ok, %{services: services}} = Sandbox.info(sandbox)

        Enum.find_value(services, fn
          {_, %{status: :running, os_pid: pid} = service} when is_integer(pid) -> service
          _ -> nil
        end)
      end,
      "The local foreground process did not start"
    )
  end

  defp put_profile(name, profile) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, name, profile))
  end
end
