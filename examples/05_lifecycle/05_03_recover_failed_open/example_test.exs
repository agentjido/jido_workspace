Code.require_file("../support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.ReopenReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Shell.VFS.MountTable
  alias Jido.Workspace
  alias Jido.Workspace.{Error, ProfileSession, Sandbox}
  alias Jido.Workspace.Examples.ReopenReport
  import Jido.Workspace.Examples.LifecycleSupport

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))
    assert {:ok, workspace} = Workspace.open(profile: :memory)
    {controller, _memory} = provider(workspace, :memory)
    assert :ok = Workspace.write(workspace, "report.txt", "Saved report")
    assert {:ok, snapshot} = Workspace.save(workspace)
    assert :ok = Workspace.close(workspace)

    await(
      fn -> controller not in children(ProfileSession.Supervisor) end,
      "The snapshot fixture did not close"
    )

    %{snapshot: snapshot}
  end

  test "an owner exit during memory allocation prevents the caller from receiving a handle",
       %{snapshot: snapshot} do
    owner =
      spawn_link(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(owner)

    {task, namespace} =
      with_suspended(MountTable, fn ->
        task =
          Task.async(fn -> Workspace.open(profile: :memory, from: snapshot, owner: owner) end)

        namespace = pending_mount()
        send(owner, :stop)
        assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
        {task, namespace}
      end)

    assert {:error, %Error{code: :owner_unavailable, operation: :open}} = Task.await(task)
    assert [] = MountTable.list(namespace)
  end

  test "the memory tree is released if the caller exits before handing it to a live owner",
       %{snapshot: snapshot} do
    owner = self()
    before = children(ProfileSession.Supervisor)

    namespace =
      with_suspended(MountTable, fn ->
        {opener, ref} =
          spawn_monitor(fn ->
            Workspace.open(profile: :memory, from: snapshot, owner: owner)
          end)

        namespace = pending_mount()
        assert Process.exit(opener, :kill)
        assert_receive {:DOWN, ^ref, :process, ^opener, :killed}
        namespace
      end)

    await(fn -> children(ProfileSession.Supervisor) == before end, "Profile controller retained")
    assert [] = MountTable.list(namespace)

    # A caller can hand off a successful open and then exit.
    task = Task.async(fn -> Workspace.open(profile: :memory, from: snapshot, owner: owner) end)
    assert {:ok, workspace} = Task.await(task)
    assert_report_and_close(workspace)
  end

  test "a late memory allocation releases its mount and leaves the saved report available",
       %{snapshot: snapshot} do
    before = children(ProfileSession.Supervisor)

    namespace =
      with_suspended(MountTable, fn ->
        task = Task.async(fn -> ReopenReport.reopen(:memory, snapshot, 1_000) end)
        namespace = pending_mount()

        assert {:retry_open, ^snapshot, %Error{code: :open_timeout, operation: :open}} =
                 Task.await(task)

        namespace
      end)

    await(fn -> children(ProfileSession.Supervisor) == before end, "Profile controller retained")
    assert [] = MountTable.list(namespace)
    assert {:ok, workspace} = ReopenReport.reopen(:memory, snapshot, 5_000)
    assert_report_and_close(workspace)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to verify late Docker allocation"
  end

  test "a late Docker allocation releases its root and leaves the saved report available",
       %{tmp_dir: root, snapshot: snapshot} do
    temp = docker_tmpdir(root)
    before = children(ProfileSession.Supervisor)

    with_suspended(Sandbox.Supervisor, fn ->
      task = Task.async(fn -> ReopenReport.reopen(:docker, snapshot, 1_000) end)

      await(
        fn -> pending_call(Sandbox.Supervisor, &match?({:start_child, _}, &1)) end,
        "Docker allocation did not reach the sandbox supervisor"
      )

      assert {:retry_open, ^snapshot, %Error{code: :open_timeout}} = Task.await(task)
    end)

    await(
      fn -> children(ProfileSession.Supervisor) == before end,
      "Profile controller retained",
      15_000
    )

    assert [] = File.ls!(temp)
    assert {:ok, workspace} = ReopenReport.reopen(:docker, snapshot, 15_000)
    assert_report_and_close(workspace)
    assert [] = File.ls!(temp)
  end

  cond do
    System.get_env("JIDO_SANDBOX_DOCKER") != "1" ->
      @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to verify failed Docker allocation"

    match?({"0\n", 0}, System.cmd("/usr/bin/id", ["-u"])) ->
      @tag skip: "Run as a non-root user to check directory permissions"

    true ->
      :ok
  end

  test "a failed Docker allocation reports unconfirmed cleanup and retries root removal",
       %{tmp_dir: root, snapshot: snapshot} do
    temp = docker_tmpdir(root)
    before = children(Sandbox.Supervisor)
    {entered, release} = hold_image_inspection(root)
    task = Task.async(fn -> ReopenReport.reopen(:docker, snapshot, 25_000) end)

    try do
      await(fn -> File.exists?(entered) end, "Docker image inspection did not start", 5_000)
      assert [name] = File.ls!(temp)
      assert "jido-sandbox-" <> id = name
      assert :ok = File.chmod(temp, 0o500)
      File.touch!(release)

      assert {:error, %Error{code: :cleanup_unconfirmed, operation: :open}} = Task.await(task)
      assert {:error, :not_found} = Sandbox.attach(id)
      assert File.dir?(Path.join(temp, name))
    after
      File.chmod!(temp, 0o700)
      File.touch!(release)
    end

    await(
      fn -> children(Sandbox.Supervisor) == before end,
      "Sandbox cleanup did not retry",
      8_000
    )

    assert [] = File.ls!(temp)
  end

  defp assert_report_and_close(workspace) do
    try do
      assert {:ok, "Saved report"} = Workspace.read(workspace, "report.txt")
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp with_suspended(server, fun) do
    assert :ok = :sys.suspend(server)

    try do
      fun.()
    after
      :sys.resume(server)
    end
  end

  defp pending_mount do
    {:attach, namespace, "/", _} =
      await(
        fn -> pending_call(MountTable, &match?({:attach, _, "/", _}, &1)) end,
        "Memory allocation did not reach the mount table"
      )

    namespace
  end

  defp pending_call(server, matches?) do
    {:messages, messages} = Process.info(Process.whereis(server), :messages)

    Enum.find_value(messages, fn
      {:"$gen_call", _, request} -> if matches?.(request), do: request
      _ -> nil
    end)
  end

  defp children(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.sort()
  end

  defp docker_tmpdir(root) do
    temp = Path.join(root, "sandboxes")
    File.mkdir!(temp)
    set_env("TMPDIR", temp)
    temp
  end

  defp hold_image_inspection(root) do
    bin = Path.join(root, "bin")
    File.mkdir!(bin)
    docker = System.find_executable("docker")
    assert is_binary(docker)

    entered = Path.join(root, "inspection-started")
    release = Path.join(root, "fail-inspection")
    shim = Path.join(bin, "docker")

    File.write!(shim, """
    #!/bin/sh
    if [ "$3" = image ] && [ "$4" = inspect ]; then
      : > "$JIDO_TEST_INSPECTION_STARTED"
      for delay in $(seq 1 200); do
        if [ -e "$JIDO_TEST_FAIL_INSPECTION" ]; then
          exit 1
        fi
        sleep 0.05
      done
      exit 1
    fi
    exec "$JIDO_TEST_DOCKER" "$@"
    """)

    File.chmod!(shim, 0o700)
    set_env("JIDO_TEST_DOCKER", docker)
    set_env("JIDO_TEST_INSPECTION_STARTED", entered)
    set_env("JIDO_TEST_FAIL_INSPECTION", release)
    set_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    {entered, release}
  end

  defp set_env(key, value) do
    previous = System.get_env(key)
    System.put_env(key, value)

    on_exit(fn ->
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end)
  end
end
