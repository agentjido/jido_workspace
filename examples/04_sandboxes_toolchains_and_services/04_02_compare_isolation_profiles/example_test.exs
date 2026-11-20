Code.require_file(
  "../../03_security_and_policy/03_03_limit_tools_and_dependencies/example.ex",
  __DIR__
)

Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.IsolationProfilesTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.ReadWithApprovedTool
  import Jido.Workspace.Examples.LifecycleSupport

  @path "reports/report.txt"
  @report "Reviewed report\n"

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    memory = Map.merge(profiles.memory, %{tools: ["cat"], require: %{isolation: :mediated}})

    local = %{
      provider: :local,
      policy: :full_access,
      store: "reports",
      tools: ["/bin/cat"],
      require: %{isolation: :process}
    }

    docker = Map.put(profiles.docker, :tools, ["cat"])
    gvisor = %{docker | provider: :gvisor, require: %{docker.require | isolation: :gvisor}}

    Application.put_env(:jido_workspace, :profiles, %{
      memory: memory,
      local: local,
      docker: docker,
      gvisor: gvisor,
      wrong_runtime: %{docker | require: gvisor.require}
    })

    fixture = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    outside = Path.expand(Path.join(root, "outside-fixture.txt"))
    File.write!(outside, fixture)

    snapshot =
      with_workspace([profile: :memory], fn workspace ->
        assert :ok = Workspace.mkdir(workspace, "reports")
        assert :ok = Workspace.write(workspace, @path, @report)
        assert {:ok, snapshot} = Workspace.save(workspace)
        snapshot
      end)

    %{snapshot: snapshot, outside: outside, fixture: fixture}
  end

  test "Memory and Local read the same saved report with different host access", ctx do
    with_workspace([profile: :memory, from: ctx.snapshot], fn workspace ->
      check_report(workspace, "cat", ctx, %{
        provider: :memory,
        isolation: :mediated,
        network: :disabled
      })

      check_fixture_hidden(workspace, ctx)
    end)

    with_workspace([profile: :local, from: ctx.snapshot], fn workspace ->
      check_report(workspace, "/bin/cat", ctx, %{
        provider: :local,
        isolation: :process,
        network: :host
      })

      assert {:error, %Error{code: :invalid_input}} = Workspace.read(workspace, ctx.outside)

      assert {:ok, %Execution{exit_status: 0, output: output}} =
               Workspace.run(workspace, ["/bin/cat", ctx.outside])

      assert output == ctx.fixture
    end)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the installed container runtimes"
  end

  test "run the report on installed runtimes and refuse an unavailable gVisor", ctx do
    assert {runtimes, 0} =
             docker(["info", "--format", "{{range $name, $_ := .Runtimes}}{{$name}} {{end}}"])

    check_container(:docker, :container, "runc", ctx)

    if "runsc" in String.split(runtimes) do
      check_container(:gvisor, :gvisor, "runsc", ctx)
    else
      sandbox_roots = Path.expand(Path.join(ctx.tmp_dir, "sandboxes"))
      File.mkdir!(sandbox_roots)
      set_env("TMPDIR", sandbox_roots)

      assert {:error,
              %Error{
                code: :runtime_unavailable,
                operation: :open,
                details: %{runtime: "runsc"}
              }} = Workspace.open(profile: :gvisor, from: ctx.snapshot)

      assert File.ls!(sandbox_roots) == []
    end
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the isolation requirement"
  end

  test "a runc workspace cannot meet an exact gVisor requirement", %{snapshot: snapshot} do
    assert {:error,
            %Error{
              code: :unsupported_capability,
              operation: :open,
              details: %{capability: :isolation}
            }} = Workspace.open(profile: :wrong_runtime, from: snapshot)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check a rejected container create"
  end

  test "a rejected runsc launch does not retry on runc and leaves the tree usable", ctx do
    attempts = reject_container_create(ctx.tmp_dir)

    with_workspace([profile: :gvisor, from: ctx.snapshot], fn workspace ->
      {_, sandbox} = provider(workspace, :native)
      clean_up_docker_on_failure(sandbox)

      assert {:error, %Error{code: :start_failed, operation: :run}} =
               ReadWithApprovedTool.read(workspace, "cat", @path)

      assert File.read!(attempts) == "runsc\n"
      assert containers(sandbox) == []
      assert {:ok, %{phase: :ready}} = Workspace.info(workspace)
      assert :ok = Workspace.write(workspace, "notes.txt", "The required runtime failed.")
      assert {:ok, %{kind: "snapshot"}} = Workspace.save(workspace)
    end)
  end

  defp check_report(workspace, tool, ctx, expected) do
    assert {:ok, %{capabilities: capabilities}} = Workspace.info(workspace)
    assert Map.take(capabilities, Map.keys(expected)) == expected
    assert {:ok, @report} = ReadWithApprovedTool.read(workspace, tool, @path)
    assert Workspace.save(workspace) == {:ok, ctx.snapshot}
  end

  defp check_fixture_hidden(workspace, ctx) do
    assert {:ok, %Execution{status: :exited, exit_status: code, output: output}} =
             Workspace.run(workspace, ["cat", ctx.outside])

    assert code != 0
    refute output =~ ctx.fixture
  end

  defp check_container(profile, isolation, runtime, ctx) do
    with_workspace([profile: profile, from: ctx.snapshot], fn workspace ->
      {_, sandbox} = provider(workspace, :native)
      clean_up_docker_on_failure(sandbox)

      check_report(workspace, "cat", ctx, %{
        provider: profile,
        isolation: isolation,
        runtime: runtime,
        network: :disabled
      })

      assert [container] = containers(sandbox)
      assert {reported, 0} = docker(["inspect", "--format", "{{.HostConfig.Runtime}}", container])
      assert String.trim(reported) == runtime
      check_fixture_hidden(workspace, ctx)
    end)
  end

  defp reject_container_create(root) do
    docker = System.find_executable("docker")
    assert is_binary(docker)
    attempts = Path.expand(Path.join(root, "runtime-attempts"))
    shim = Path.join(root, "docker")

    File.write!(shim, ~S"""
    #!/bin/sh
    case "$3" in
      info)
        printf 'cgroupfs true true true\nrunc runsc\n'
        exit 0
        ;;
      create)
        while [ "$#" -gt 1 ] && [ "$1" != --runtime ]; do shift; done
        printf '%s\n' "$2" >> "$JIDO_ISOLATION_ATTEMPTS"
        printf '%s\n' 'The fixture refused to create a container.' >&2
        exit 1
        ;;
    esac
    exec "$JIDO_ISOLATION_DOCKER" "$@"
    """)

    File.chmod!(shim, 0o700)
    set_env("JIDO_ISOLATION_DOCKER", docker)
    set_env("JIDO_ISOLATION_ATTEMPTS", attempts)
    set_env("PATH", Path.expand(root) <> ":" <> System.fetch_env!("PATH"))
    attempts
  end

  defp set_env(key, value) do
    previous = System.get_env(key)
    System.put_env(key, value)

    on_exit(fn ->
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end)
  end

  defp with_workspace(opts, fun) do
    assert {:ok, workspace} = Workspace.open(opts)

    try do
      fun.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end
end
