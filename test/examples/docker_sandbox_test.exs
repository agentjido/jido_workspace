defmodule Jido.Workspace.Sandbox.DockerTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :docker
  @moduletag capture_log: true
  @moduletag timeout: 120_000
  if System.get_env("JIDO_SANDBOX_DOCKER") != "1",
    do: @moduletag(skip: "Set JIDO_SANDBOX_DOCKER=1 for live Docker tests")

  alias Jido.Workspace.Sandbox
  alias Jido.Workspace.Sandbox.Backends.Docker
  alias Jido.Workspace.TestSupport.{Actions, BoundaryAgent}

  defp image, do: System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest")
  defp runtime, do: System.get_env("JIDO_SANDBOX_RUNTIME", "runc")

  defp box(opts \\ []) do
    {:ok, sandbox} =
      Sandbox.open(Keyword.merge([backend: {Docker, [image: image(), runtime: runtime()]}], opts))

    on_exit(fn ->
      result = if Process.alive?(sandbox.pid), do: Sandbox.destroy(sandbox), else: :ok
      # A failed assertion must still remove this test's resources.
      ids = containers(sandbox)

      if ids != [],
        do: System.cmd("docker", ["rm", "--force", "--volumes"] ++ ids, stderr_to_stdout: true)

      File.rm_rf!(sandbox.root)
      assert result == :ok
      assert ids == []
      assert containers(sandbox) == []
    end)

    sandbox
  end

  defp containers(sandbox) do
    {ids, 0} =
      System.cmd(
        "docker",
        ["ps", "--all", "--quiet", "--filter", "label=dev.jido.workspace.sandbox=" <> sandbox.id],
        stderr_to_stdout: true
      )

    String.split(ids)
  end

  test "direct calls use container files, exact arguments, limits, and disabled network" do
    sandbox = box()

    assert %{
             cancellation: :container,
             network: :disabled,
             beam_call: false,
             image: "sha256:" <> _
           } = Sandbox.capabilities(sandbox)

    :ok = Sandbox.write(sandbox, "nested/input", "from host")

    assert {:ok, %{output: "from host", exit_status: 0}} =
             Sandbox.exec(sandbox, "/bin/cat", ["input"], dir: "nested")

    assert {:ok, %{output: "value;$(touch bad)", exit_status: 0}} =
             Sandbox.exec(sandbox, "/bin/busybox", ["printf", "%s", "value;$(touch bad)"])

    refute File.exists?(Path.join(sandbox.root, "bad"))

    assert {:ok, %{output: "container", exit_status: 0}} =
             Sandbox.exec(
               sandbox,
               "/bin/sh",
               ["-c", "printf '%s' \"$EXAMPLE\" > output; cat output"],
               env: [{"EXAMPLE", "container"}]
             )

    assert {:ok, "container"} = Sandbox.read(sandbox, "output")

    assert {:ok, %{output: combined, exit_status: 7, status: :exited}} =
             Sandbox.exec(sandbox, "/bin/sh", ["-c", "printf out; printf err >&2; exit 7"])

    assert combined in ["outerr", "errout"]

    assert {:ok, %{output: "1234", truncated: true}} =
             Sandbox.exec(sandbox, "/bin/busybox", ["printf", "12345678"], output_limit: 4)

    assert {:ok, %{exit_status: 0}} =
             Sandbox.exec(sandbox, "/bin/sh", [
               "-c",
               "test ! -S /var/run/docker.sock && test ! -e /host && test -z \"$HOME_SECRET\" && ! touch /outside 2>/dev/null"
             ])

    {:ok, %{services: services}} = Sandbox.info(sandbox)
    service = services |> Map.values() |> hd()
    {json, 0} = System.cmd("docker", ["inspect", service.container])
    [container] = Jason.decode!(json)
    assert container["HostConfig"]["NetworkMode"] == "none"
    assert container["HostConfig"]["ReadonlyRootfs"]
    assert container["HostConfig"]["CapDrop"] == ["ALL"]
    assert container["HostConfig"]["Runtime"] == runtime()
    assert container["HostConfig"]["PidsLimit"] == 256
    assert container["HostConfig"]["Memory"] == 256 * 1024 * 1024
    assert [%{"Destination" => "/workspace", "RW" => true}] = container["Mounts"]
    assert :ok = Sandbox.destroy(sandbox)
    assert containers(sandbox) == []
    refute File.exists?(sandbox.root)
  end

  test "timeout and explicit stop remove the whole container" do
    sandbox = box()

    assert {:ok, %{status: :timed_out, exit_status: 124}} =
             Sandbox.exec(sandbox, "/bin/sleep", ["10"], timeout: 500)

    assert containers(sandbox) == []

    {:ok, id} =
      Sandbox.start_service(sandbox, %{
        kind: :exec,
        executable: "/bin/sh",
        args: ["-c", "(sleep 2; echo escaped > escaped) & echo ready > ready; wait"]
      })

    wait_file(sandbox, "ready")
    {:ok, %{container: container}} = Sandbox.service_status(sandbox, id)
    assert :ok = Sandbox.stop_service(sandbox, id)
    assert {:ok, %{status: :stopped}} = Sandbox.service_status(sandbox, id)
    {_, status} = System.cmd("docker", ["inspect", container], stderr_to_stdout: true)
    assert status != 0
    Process.sleep(2_100)
    refute File.exists?(Path.join(sandbox.root, "escaped"))
    assert :ok = Sandbox.stop_service(sandbox, id)
    assert containers(sandbox) == []
  end

  test "caller exit, close, and attach preserve identity; controller shutdown cleans containers" do
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        {:ok, sandbox} = Sandbox.open(provider: :docker, image: image())
        send(parent, sandbox)
      end)

    assert_receive %Sandbox{} = sandbox, 30_000

    on_exit(fn ->
      if Process.alive?(sandbox.pid), do: Sandbox.destroy(sandbox)
      ids = containers(sandbox)
      if ids != [], do: System.cmd("docker", ["rm", "--force", "--volumes"] ++ ids)
      File.rm_rf!(sandbox.root)
      assert ids == []
    end)

    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}

    {:ok, _id} =
      Sandbox.start_service(sandbox, %{kind: :exec, executable: "/bin/sleep", args: ["30"]})

    assert :ok = Sandbox.close(sandbox)
    assert {:ok, attached} = Sandbox.attach(sandbox.id)
    assert attached.provider == :docker
    assert attached.pid == sandbox.pid
    assert Sandbox.capabilities(%{attached | provider: :local, root: "/"}).provider == :docker
    assert :ok = DynamicSupervisor.terminate_child(Jido.Workspace.Sandbox.Supervisor, sandbox.pid)
    assert containers(sandbox) == []
    assert {:error, :not_found} = Sandbox.attach(sandbox.id)
  end

  test "policy, stale views, and unsupported capabilities refuse work before creation" do
    sandbox = box()
    restricted = box(policy: :read_only)
    assert {:error, {:policy_denied, :execute}} = Sandbox.exec(restricted, "/bin/true", [])
    assert {:error, {:policy_denied, :write}} = Sandbox.write(restricted, "blocked", "bad")
    assert containers(restricted) == []
    {:ok, view} = Sandbox.file_view(sandbox)
    :ok = Sandbox.write(sandbox, "changed", "new")

    assert {:error, :stale_file_view} =
             Sandbox.exec(sandbox, "/bin/touch", ["blocked"], files: view)

    assert {:error, {:unsupported_capability, :beam_call}} =
             Sandbox.start_service(sandbox, %{kind: :beam})

    assert {:error, {:unsupported_capability, :beam_call}} =
             Sandbox.call(sandbox, "missing", :os, :getpid, [])

    assert {:error, :invalid_service} =
             Sandbox.start_service(sandbox, %{kind: :exec, executable: "/bin/true", args: [123]})

    assert {:error, :enoent} = Sandbox.exec(sandbox, "/bin/true", [], dir: "missing")
    assert {:error, {:docker, "start", _, _}} = Sandbox.exec(sandbox, "/missing-command", [])
    assert containers(sandbox) == []
    refute File.exists?(Path.join(sandbox.root, "blocked"))
  end

  test "the same Docker resource works through Jido Actions and Agent Signals" do
    sandbox = box()
    exercise_boundaries(sandbox)
  end

  test "missing images and runtimes leave no owned root; runsc never falls back" do
    root =
      Path.join(System.tmp_dir!(), "jido-docker-failed-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, {:image_unavailable, _}} =
             Sandbox.open(
               provider: :docker,
               image: "jido-workspace-does-not-exist:missing",
               root: root
             )

    refute File.exists?(root)

    {runtimes, 0} =
      System.cmd("docker", [
        "info",
        "--format",
        "{{range $name, $_ := .Runtimes}}{{$name}} {{end}}"
      ])

    if "runsc" in String.split(runtimes) do
      sandbox = box(backend: {Docker, [image: image(), runtime: "runsc"]})
      assert Sandbox.capabilities(sandbox).isolation == :gvisor

      assert {:ok, %{output: "gvisor", exit_status: 0}} =
               Sandbox.exec(sandbox, "/bin/busybox", ["printf", "gvisor"])

      exercise_boundaries(sandbox)
    else
      assert {:error, {:runtime_unavailable, "runsc"}} =
               Sandbox.open(provider: :gvisor, image: image(), root: root)

      refute File.exists?(root)
    end
  end

  defp exercise_boundaries(sandbox) do
    start_supervised!({Jido, name: __MODULE__.Runtime})
    store = start_supervised!({Agent, fn -> %{} end})
    access = %{store: store, reply_to: self(), resources: %{"container" => {:sandbox, sandbox}}}
    :ok = Sandbox.write(sandbox, "input", "through boundaries")

    params = %{
      request_id: "action",
      resource_id: "container",
      executable: "/bin/cat",
      args: ["input"]
    }

    assert {:ok, %{result: %{output: "through boundaries", exit_status: 0}}} =
             Jido.Exec.run(Actions.Exec, params, %{workspace_access: access}, max_retries: 0)

    agent =
      start_supervised!(
        {Jido.AgentServer,
         jido: __MODULE__.Runtime,
         agent: BoundaryAgent,
         initial_state: %{workspace_access: access}}
      )

    assert %{result: %{output: "through boundaries", exit_status: 0}} = request(agent, params)

    assert %{result: %{exit_status: 7}} =
             request(agent, %{params | executable: "/bin/sh", args: ["-c", "exit 7"]})

    assert %{error: %{code: "resource_not_found"}} =
             request(agent, %{params | resource_id: "unknown"}, "failed")

    assert {:error, _} =
             Jido.Exec.run(Actions.Exec, %{params | args: [42]}, %{workspace_access: access},
               max_retries: 0
             )
  end

  defp request(agent, params, outcome \\ "succeeded") do
    signal =
      Jido.Signal.new!("jido.workspace.v1.sandbox.exec.requested", params,
        source: "/sandbox/docker-test"
      )

    Jido.AgentServer.call(agent, signal, 30_000)
    type = "jido.workspace.v1.sandbox.exec." <> outcome
    causation = signal.id

    assert_receive {:signal, %Jido.Signal{type: ^type, data: %{causation_id: ^causation} = data}},
                   30_000

    assert data.resource_id == params.resource_id
    assert data.request_id == params.request_id
    assert {:ok, _} = Jason.encode(data)
    data
  end

  defp wait_file(sandbox, path, remaining \\ 200)
  defp wait_file(_, _, 0), do: flunk("Container did not become ready")

  defp wait_file(sandbox, path, remaining) do
    case Sandbox.read(sandbox, path) do
      {:ok, _} ->
        :ok

      _ ->
        Process.sleep(20)
        wait_file(sandbox, path, remaining - 1)
    end
  end
end
