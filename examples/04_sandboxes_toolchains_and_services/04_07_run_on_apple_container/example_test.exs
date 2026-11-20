Code.require_file("example.ex", __DIR__)
Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.AppleContainerTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  if System.get_env("JIDO_SANDBOX_APPLE") != "1",
    do: @moduletag(skip: "Set JIDO_SANDBOX_APPLE=1 to run live Apple Container tests")

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.AppleContainer
  import Jido.Workspace.Examples.LifecycleSupport, only: [await: 3, configure: 1, provider: 2]

  setup %{tmp_dir: dir} do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    image = "localhost/jido-workspace-apple-fixture:" <> suffix
    source = System.get_env("JIDO_SANDBOX_APPLE_IMAGE", "alpine:latest")
    assert {_, 0} = cli(["image", "tag", source, image])

    on_exit(fn ->
      leaked = containers(image)
      Enum.each(leaked, fn id -> cli(["delete", "--force", id]) end)
      assert {_, 0} = cli(["image", "delete", image])
      assert leaked == []
    end)

    configure(Path.join(dir, "snapshots"))
    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    apple = %{
      provider: :apple_container,
      image: image,
      policy: :full_access,
      store: "reports",
      tools: ["/bin/cp", "/bin/sh", "/bin/sleep"],
      require: %{isolation: :container, cancellation: :container, network: :disabled}
    }

    profiles =
      Map.merge(profiles, %{
        apple: apple,
        apple_reader: %{apple | policy: [:read, :execute, :import]},
        apple_pipe: %{apple | require: %{stdin: :pipe}},
        apple_pids: %{apple | require: %{runtime_limits: %{pids: 256}}}
      })

    Application.put_env(:jido_workspace, :profiles, profiles)
    %{image: image}
  end

  test "copy with literal argv and cwd, then reopen the saved result on memory", %{image: image} do
    workspace = open(:apple)
    {_controller, sandbox} = provider(workspace, :native)

    assert {:ok, %{capabilities: %{provider: :apple_container, isolation: :container}}} =
             Workspace.info(workspace)

    assert {:ok, snapshot} = AppleContainer.copy_and_save(workspace, "Reviewed report\n")
    assert containers(image) == []
    assert :ok = Workspace.close(workspace)
    refute File.exists?(sandbox.root)

    memory = open(:memory, snapshot)

    assert {:ok, "Reviewed report\n"} =
             Workspace.read(memory, "reports today/reviewed report.txt")

    assert :ok = Workspace.close(memory)
  end

  test "cancel a running container before writing or saving again", %{image: image} do
    workspace = open(:apple)
    ref = make_ref()
    observer = self()

    run =
      Task.async(fn ->
        Workspace.run(
          workspace,
          ["/bin/sh", "-c", "(sleep 20 && printf late > late.txt) & printf ready; wait"],
          notify_start: {observer, ref}
        )
      end)

    assert_receive {:workspace_command_started, ^ref, execution_id}, 5_000

    await(
      fn ->
        match?({:ok, %{bytes: "ready", done?: false}}, Workspace.output(workspace, execution_id))
      end,
      "start writer",
      5_000
    )

    assert [container] = containers(image)
    assert {:error, %Error{code: :busy}} = Workspace.save(workspace)

    assert :ok = Workspace.cancel(workspace, execution_id)
    assert {:ok, %Execution{status: :cancelled, exit_status: nil}} = Task.await(run, 12_000)
    assert container not in all_ids()
    assert :ok = Workspace.write(workspace, "after.txt", "confirmed")
    assert {:ok, _} = Workspace.save(workspace)
    assert :ok = Workspace.close(workspace)
  end

  test "check read-only mounts, loopback, output and time limits, and refused requirements", %{
    image: image,
    tmp_dir: dir
  } do
    assert {:error, %Error{code: :unsupported_capability, details: %{capability: :stdin}}} =
             Workspace.open(profile: :apple_pipe)

    assert {:error,
            %Error{code: :unsupported_capability, details: %{capability: :runtime_limits}}} =
             Workspace.open(profile: :apple_pids)

    outside = Path.join(dir, "outside.txt")
    File.write!(outside, "host file")
    writer = open(:apple)
    assert :ok = Workspace.write(writer, "input.txt", "mounted")
    assert {:ok, snapshot} = Workspace.save(writer)

    reader = open(:apple_reader, snapshot)

    inspection = """
    set -eu
    test "$(ls /sys/class/net)" = lo
    test ! -e "$1"
    test "$(cat /workspace/input.txt)" = mounted
    if touch /workspace/blocked 2>/dev/null; then exit 1; fi
    if touch /outside-workspace 2>/dev/null; then exit 1; fi
    """

    assert {:ok, %Execution{status: :exited, exit_status: 0}} =
             Workspace.run(reader, ["/bin/sh", "-c", inspection, "check", outside])

    assert {:ok, %Execution{output: "1234", truncated: true, exit_status: 7}} =
             Workspace.run(writer, ["/bin/sh", "-c", "printf 12345678; exit 7"], output_limit: 4)

    assert {:ok, %Execution{status: :timed_out, exit_status: nil}} =
             Workspace.run(writer, ["/bin/sleep", "20"], timeout_ms: 750)

    assert containers(image) == []
    assert :ok = Workspace.close(reader)
    assert :ok = Workspace.close(writer)
  end

  defp open(profile, snapshot \\ nil) do
    opts = if snapshot, do: [profile: profile, from: snapshot], else: [profile: profile]
    assert {:ok, workspace} = Workspace.open(opts)
    on_exit(fn -> Workspace.close(workspace) end)
    workspace
  end

  defp all_ids do
    assert {output, 0} = cli(["list", "--all", "--quiet"])
    String.split(output)
  end

  defp containers(image) do
    assert {output, 0} = cli(["list", "--all", "--format", "json"])

    for %{"id" => id, "configuration" => %{"image" => %{"reference" => ^image}}} <-
          Jason.decode!(output),
        do: id
  end

  defp cli(args), do: System.cmd("container", args, stderr_to_stdout: true)
end
