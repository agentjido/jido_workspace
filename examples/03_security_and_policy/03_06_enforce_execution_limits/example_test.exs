Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.ExecutionLimitsTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  import Jido.Workspace.Examples.LifecycleSupport

  @command_limits %{timeout_ms: 4_000, output_limit: 128}
  @runtime_limits %{
    cpu_millicores: 1_000,
    memory_bytes: 256 * 1024 * 1024,
    pids: 256,
    tmp_bytes: 64 * 1024 * 1024
  }

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))
    configure_profile(:memory, limits: @command_limits)

    configure_profile(:docker,
      limits: @command_limits,
      require: %{runtime_limits: @runtime_limits}
    )
  end

  test "memory reports and enforces command limits without claiming runtime controls" do
    with_workspace(:memory, fn workspace ->
      assert {:ok,
              %{
                command_limits: @command_limits,
                capabilities: %{provider: :memory, runtime_limits: %{} = limits}
              }} = Workspace.info(workspace)

      assert limits == %{}
      check_output_cap(workspace)
      check_deadline(workspace, ["sleep", "30"], [], "Sleeping")
    end)
  end

  test "open refuses a runtime ceiling that memory cannot enforce" do
    configure_profile(:memory, require: %{runtime_limits: %{pids: 256}})

    assert {:error,
            %Error{
              operation: :open,
              code: :unsupported_capability,
              details: %{capability: :runtime_limits}
            }} = Workspace.open(profile: :memory)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 for the live execution limit checks"
  end

  test "Docker reports the active cgroup limits and bounds temporary storage" do
    with_workspace(:docker, fn workspace ->
      assert {:ok,
              %{
                command_limits: @command_limits,
                capabilities: %{provider: :docker, runtime_limits: @runtime_limits}
              }} = Workspace.info(workspace)

      check_output_cap(workspace)
      check_cgroup(workspace)
      check_temporary_storage(workspace)

      check_deadline(
        workspace,
        ["sh", "-c", "printf ready; IFS= read -r line"],
        [stdin: :pipe],
        "ready"
      )
    end)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check refusal and checkout release"
  end

  test "Docker refuses a stricter ceiling and releases the checkout", %{tmp_dir: root} do
    checkout = Path.join(root, "checkout")
    File.mkdir!(checkout)

    configure_profile(:docker,
      checkout: checkout,
      require: %{runtime_limits: %{pids: @runtime_limits.pids - 1}}
    )

    assert {:error,
            %Error{
              operation: :open,
              code: :unsupported_capability,
              details: %{capability: :runtime_limits}
            }} = Workspace.open(profile: :docker)

    configure_profile(:docker, require: %{runtime_limits: %{pids: @runtime_limits.pids + 1}})

    with_workspace(:docker, fn workspace ->
      assert {:ok, %{capabilities: %{runtime_limits: %{pids: 256}}}} = Workspace.info(workspace)
      assert :ok = Workspace.write(workspace, "report.txt", "Accepted")
    end)

    assert File.read!(Path.join(checkout, "report.txt")) == "Accepted"
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to probe admission with a missing controller"
  end

  test "Docker omits a limit when the engine reports that its controller is absent", %{
    tmp_dir: root
  } do
    hide_pid_controller(root)

    assert {:error,
            %Error{code: :unsupported_capability, details: %{capability: :runtime_limits}}} =
             Workspace.open(profile: :docker)

    configure_profile(:docker, require: %{runtime_limits: Map.delete(@runtime_limits, :pids)})

    with_workspace(:docker, fn workspace ->
      assert {:ok, %{capabilities: %{runtime_limits: limits}}} = Workspace.info(workspace)
      assert limits == Map.delete(@runtime_limits, :pids)
    end)
  end

  defp check_output_cap(workspace) do
    bytes = String.duplicate("report\n", 64)
    cap = binary_part(bytes, 0, @command_limits.output_limit)
    assert :ok = Workspace.write(workspace, "report.txt", bytes)

    assert {:ok, %Execution{status: :exited, exit_status: 0, output: ^cap, truncated: true}} =
             Workspace.run(workspace, ["cat", "report.txt"], output_limit: 1_024)

    assert {:ok, %Execution{exit_status: 0, output: "report", truncated: true}} =
             Workspace.run(workspace, ["cat", "report.txt"], output_limit: 6)
  end

  defp check_deadline(workspace, argv, opts, prefix) do
    task = Task.async(fn -> Workspace.run(workspace, argv, [timeout_ms: 30_000] ++ opts) end)

    id =
      await(
        fn ->
          case Workspace.info(workspace) do
            {:ok, %{active_execution_id: id}} -> id
            _ -> nil
          end
        end,
        "The command did not start"
      )

    await(
      fn ->
        case Workspace.output(workspace, id) do
          {:ok, %{bytes: bytes, done?: false}} -> String.starts_with?(bytes, prefix)
          _ -> false
        end
      end,
      "The command did not reach the output barrier",
      3_500
    )

    assert {:error, %Error{code: :busy}} = Workspace.save(workspace)

    assert {:ok, %Execution{id: ^id, status: :timed_out, exit_status: nil, output: bytes}} =
             Task.await(task, 10_000)

    assert String.starts_with?(bytes, prefix)
    assert :ok = Workspace.write(workspace, "review.txt", "Stopped")
    assert {:ok, %{kind: "snapshot"}} = Workspace.save(workspace)
  end

  defp check_cgroup(workspace) do
    files = for name <- ~w(pids.max memory.max cpu.max), do: "/sys/fs/cgroup/" <> name

    assert {:ok, %Execution{exit_status: 0, output: output, truncated: false}} =
             Workspace.run(workspace, ["cat" | files])

    assert [pids, memory, quota, period] = String.split(output)
    assert String.to_integer(pids) == @runtime_limits.pids
    assert String.to_integer(memory) == @runtime_limits.memory_bytes

    assert String.to_integer(quota) * 1_000 ==
             String.to_integer(period) * @runtime_limits.cpu_millicores
  end

  defp check_temporary_storage(workspace) do
    script = ~S"""
    if message=$(dd if=/dev/zero of=/tmp/probe bs=1048576 count=65 2>&1); then
      exit 2
    fi
    case "$message" in
      *"No space left on device"*) ;;
      *) exit 3 ;;
    esac
    wc -c < /tmp/probe
    """

    assert {:ok, %Execution{exit_status: 0, output: output, truncated: false}} =
             Workspace.run(workspace, ["sh", "-c", script])

    assert output |> String.trim() |> String.to_integer() == @runtime_limits.tmp_bytes

    assert {:ok, %Execution{exit_status: 0}} =
             Workspace.run(workspace, ["sh", "-c", "test ! -e /tmp/probe"])
  end

  defp configure_profile(name, changes) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    profiles =
      Map.update!(profiles, name, fn profile ->
        Map.merge(profile, Map.new(changes), fn
          :require, current, required -> Map.merge(current, required)
          _, _, value -> value
        end)
      end)

    Application.put_env(:jido_workspace, :profiles, profiles)
  end

  defp hide_pid_controller(root) do
    docker = System.find_executable("docker")
    assert is_binary(docker)
    shim = Path.join(root, "docker")

    File.write!(shim, ~S"""
    #!/bin/sh
    if [ "$3" = info ]; then
      printf 'cgroupfs true false true\nrunc\n'
      exit 0
    fi
    exec "$JIDO_LIMITS_TEST_DOCKER" "$@"
    """)

    File.chmod!(shim, 0o700)
    set_env("JIDO_LIMITS_TEST_DOCKER", docker)
    set_env("PATH", root <> ":" <> System.fetch_env!("PATH"))
  end

  defp set_env(key, value) do
    previous = System.get_env(key)
    System.put_env(key, value)

    on_exit(fn ->
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end)
  end

  defp with_workspace(profile, fun) do
    assert {:ok, workspace} = Workspace.open(profile: profile)

    if profile == :docker do
      {_controller, sandbox} = provider(workspace, :native)
      clean_up_docker_on_failure(sandbox)
    end

    try do
      fun.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end
end
