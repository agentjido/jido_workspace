Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.SuperviseNativeProcessTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  import Jido.Workspace.Examples.LifecycleSupport

  @writer ~S"""
  /bin/sh -c '
    if [ "$1" = stubborn ]; then trap "" TERM; fi
    printf "writer %s\n" "$$"
    read -r line <"$2" && printf "%s" "$line" >late.txt
  ' writer "$1" "$2" &
  wait
  """

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))

    profile = %{
      provider: :local,
      policy: :full_access,
      runner: :erlexec,
      tools: ["/bin/sh"],
      require: %{isolation: :process, cancellation: :process_group},
      store: "reports"
    }

    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    Application.put_env(
      :jido_workspace,
      :profiles,
      Map.merge(profiles, %{native: profile, direct: %{profile | runner: :port}})
    )

    :ok
  end

  test "the profile requires group cancellation and refuses the direct-child runner" do
    assert {:error, %Error{code: :unsupported_capability, details: %{capability: :cancellation}}} =
             Workspace.open(profile: :direct)
  end

  test "short commands keep stdout, stderr, and the exit status with literal argv and cwd" do
    assert {:ok, workspace} = Workspace.open(profile: :native)
    assert :ok = Workspace.mkdir(workspace, "build")

    assert {:ok, %{capabilities: %{isolation: :process, cancellation: :process_group}}} =
             Workspace.info(workspace)

    script = ~S|printf '%s: %s\n' "${PWD##*/}" "$1"; printf 'check stderr\n' >&2; exit 7|
    argument = "report; exit 8"

    for _ <- 1..12 do
      assert {:ok,
              %Execution{
                status: :exited,
                exit_status: 7,
                output: "build: report; exit 8\ncheck stderr\n",
                truncated: false
              }} =
               Workspace.run(workspace, ["/bin/sh", "-c", script, "check", argument],
                 cwd: "build"
               )
    end

    assert :ok = Workspace.close(workspace)
  end

  test "cancel confirms the child writer has exited before save", %{tmp_dir: root} do
    {workspace, task, id, child} = start_writer(root, "cooperative")

    assert {:error, %Error{code: :busy}} = Workspace.save(workspace)
    assert :ok = Workspace.cancel(workspace, id)

    assert {:ok, %Execution{id: ^id, status: :cancelled, exit_status: nil}} = Task.await(task)
    refute process_exists?(child)
    assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "late.txt")
    assert :ok = Workspace.write(workspace, "confirmed.txt", "The writer stopped.")
    assert {:ok, %{kind: "snapshot"}} = Workspace.save(workspace)
    assert :ok = Workspace.close(workspace)
  end

  test "a child that ignores TERM keeps the tree fenced after its leader exits", %{tmp_dir: root} do
    {workspace, task, id, child} = start_writer(root, "stubborn")
    {_controller, sandbox} = provider(workspace, :native)

    try do
      assert :ok = Workspace.cancel(workspace, id)

      assert {:error, %Error{code: :quiescence_unknown, details: %{execution_id: ^id}}} =
               Task.await(task)

      assert process_exists?(child)
      assert {:ok, %{phase: :quiescence_unknown}} = Workspace.info(workspace)

      assert {:error, %Error{code: :quiescence_unknown}} =
               Workspace.write(workspace, "unconfirmed.txt", "Blocked.")

      assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)
      assert {:error, %Error{code: :cleanup_unconfirmed}} = Workspace.close(workspace)
      assert File.dir?(sandbox.root)
    after
      System.cmd("/bin/kill", ["-KILL", child], stderr_to_stdout: true)
      await(fn -> not process_exists?(child) end, "The fixture child did not exit")
    end

    assert :ok = Workspace.close(workspace)
    refute File.exists?(sandbox.root)
  end

  defp start_writer(root, mode) do
    assert {:ok, workspace} = Workspace.open(profile: :native)
    gate = Path.join(root, "writer-gate")
    assert {"", 0} = System.cmd("mkfifo", [gate])

    task =
      Task.async(fn ->
        Workspace.run(workspace, ["/bin/sh", "-c", @writer, "check", mode, gate])
      end)

    {id, child} =
      await(
        fn ->
          with {:ok, %{phase: :running, active_execution_id: id}} <- Workspace.info(workspace),
               {:ok, %{bytes: bytes}} <- Workspace.output(workspace, id),
               [_, pid] <- Regex.run(~r/\Awriter ([0-9]+)\n/, bytes) do
            {id, pid}
          else
            _ -> nil
          end
        end,
        "The child writer did not reach its gate"
      )

    assert process_exists?(child)
    {workspace, task, id, child}
  end

  defp process_exists?(pid) do
    match?({"", 0}, System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true))
  end
end
