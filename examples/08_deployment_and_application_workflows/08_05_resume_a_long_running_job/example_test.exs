Code.require_file(
  "../../06_providers_and_persistent_infrastructure/06_03_recover_an_old_command/support.exs",
  __DIR__
)

Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.ResumeJobTest do
  use ExUnit.Case, async: false

  import Jido.Workspace.Examples.RecoverySupport

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.{MachinePool, RecoveryHost, ResumeJob}

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @moduletag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the persistent job and Git fixture"
  end

  setup %{tmp_dir: root} do
    preserve_configuration()
    fixture = fixture(root)
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    review = %{profiles.memory | policy: :read_only}
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, :review, review))

    repo = Path.join(root, "results.git")
    git!(root, ["init", "--bare", "--template=", "--initial-branch=reviewed", repo])
    git!(repo, ["config", "user.name", "Workspace Example"])
    git!(repo, ["config", "user.email", "workspace@example.invalid"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    git!(repo, ["config", "core.hooksPath", Path.join(root, "empty-hooks")])
    tree = git!(repo, ["write-tree"]) |> String.trim()
    base = git!(repo, ["commit-tree", tree, "-m", "Set up review branch"]) |> String.trim()
    git!(repo, ["update-ref", "refs/heads/reviewed", base])

    Map.merge(fixture, %{repo: repo, base: base, store: Path.join(root, "results")})
  end

  test "a fresh BEAM waits for the original job and publishes only after safe writer handoff",
       ctx do
    %{host: host, machine: machine, pool: pool, tree: tree, repo: repo, base: base} = ctx
    reference = new_reference(machine, "report-job")
    reference_file = Path.join(ctx.tmp_dir, "command.json")
    File.write!(reference_file, Jason.encode!(reference))
    job_dir = RecoveryHost.job_path(tree, reference)
    report_path = Path.relative_to(Path.join(job_dir, "report"), tree)

    assert {:ok, %{id: machine_id, started_at: started_at}} =
             MachinePool.inspect_machine(pool, machine)

    old = peer()
    monitor = Process.monitor(old)

    script = """
    spawn(fn ->
      {:ok, command} = reference_file |> File.read!() |> Jason.decode!() |> Jido.Workspace.CommandRef.parse()
      {:ok, workspace} = Jido.Workspace.open(profile: :run, infrastructure: command.infrastructure)
      Jido.Workspace.run(workspace, ["write-report"], command: command)
    end)
    :submitted
    """

    assert {:submitted, _} =
             :peer.call(old, Code, :eval_string, [script, [reference_file: reference_file]])

    assert :ok = await_start(tree, reference)
    assert {:ok, old_writer} = RecoveryHost.current_writer(host, machine)
    assert :ok = :peer.cast(old, System, :halt, [73])
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 10_000

    rename_job(pool)
    fresh = peer()
    assert is_list(:peer.call(fresh, Code, :require_file, [Path.join(__DIR__, "example.ex")]))
    recovered = :peer.call(fresh, File, :read!, [reference_file]) |> Jason.decode!()

    assert {:ok, %{status: :running, exit_status: nil}} = recover(fresh, recovered, :inspect)
    assert {:ok, %{status: :running}} = recover(fresh, recovered, :wait, timeout_ms: 1_000)
    assert {:error, :cleanup_unconfirmed} = RecoveryHost.revoke_writer(host, machine, old_writer)
    assert {:error, :job_running} = publish(fresh, recovered, report_path, repo, base)
    assert_unpublished(ctx)

    assert :ok = File.touch(Path.join(job_dir, "finish"))

    assert {:ok, %{status: :exited, exit_status: 0}} =
             recover(fresh, recovered, :wait, timeout_ms: 5_000)

    assert {:error, %Error{code: :infrastructure_busy}} =
             publish(fresh, recovered, report_path, repo, base)

    assert {:ok, ^old_writer} = RecoveryHost.current_writer(host, machine)
    assert_unpublished(ctx)
    assert :ok = RecoveryHost.revoke_writer(host, machine, old_writer)

    wrong_path = Path.join(Path.dirname(report_path), "starts")

    assert {:error, :report_verification_failed} =
             publish(fresh, recovered, wrong_path, repo, base)

    assert git!(repo, ["rev-parse", "reviewed"]) == base <> "\n"

    assert {:ok, %{snapshot: snapshot, commit: commit}} =
             publish(fresh, recovered, report_path, repo, base)

    assert git!(repo, ["rev-parse", "reviewed"]) == commit <> "\n"
    assert git!(repo, ["show", "#{commit}:report.txt"]) == "complete\n"
    assert git!(repo, ["ls-tree", "--name-only", commit]) == "report.txt\n"
    assert git!(repo, ["rev-parse", "#{commit}^"]) == base <> "\n"

    assert {:ok, review} =
             Workspace.open(profile: :review, from: Jason.decode!(Jason.encode!(snapshot)))

    try do
      assert {:ok, "complete\n"} = Workspace.read(review, report_path)
      assert {:ok, "started\n"} = Workspace.read(review, wrong_path)

      assert {:error, %Error{code: :policy_denied}} =
               Workspace.write(review, report_path, "changed")
    after
      assert :ok = Workspace.close(review)
    end

    assert {:ok, %{id: ^machine_id, running: true, started_at: ^started_at}} =
             MachinePool.inspect_machine(pool, machine)
  end

  test "a stopped job cannot publish even when a report is present", ctx do
    %{machine: machine, tree: tree, repo: repo, base: base} = ctx
    reference = new_reference(machine, "stopped-job")

    report_path =
      Path.relative_to(Path.join(RecoveryHost.job_path(tree, reference), "report"), tree)

    assert {:ok, workspace} = Workspace.open(profile: :run, infrastructure: machine)
    assert :ok = Workspace.write(workspace, report_path, "complete\n")

    runner = Task.async(fn -> Workspace.run(workspace, ["write-report"], command: reference) end)
    assert :ok = await_start(tree, reference)

    assert {:ok, %{status: :exited, exit_status: status}} =
             Workspace.recover_command(:recovery, reference, :stop)

    assert status != 0
    assert {:ok, %Execution{exit_status: ^status}} = Task.await(runner, 15_000)
    assert :ok = Workspace.close(workspace)

    assert {:error, {:job_failed, ^status}} =
             ResumeJob.publish(reference, report_path, repo, base)

    assert_unpublished(ctx)
  end

  defp recover(peer, reference, action, opts \\ []),
    do:
      :peer.call(peer, Workspace, :recover_command, [:recovery, reference, action, opts], 10_000)

  defp publish(peer, reference, path, repo, base),
    do: :peer.call(peer, ResumeJob, :publish, [reference, path, repo, base], 20_000)

  defp assert_unpublished(%{repo: repo, base: base, store: store}) do
    assert git!(repo, ["rev-parse", "reviewed"]) == base <> "\n"
    assert File.ls(store) in [{:error, :enoent}, {:ok, []}]
  end

  defp rename_job(pool) do
    assert {jobs, 0} =
             MachinePool.docker(pool, [
               "ps",
               "--all",
               "--quiet",
               "--no-trunc",
               "--filter",
               "label=" <> MachinePool.scope(pool),
               "--filter",
               "name=jido-example-job-" <> pool.tag
             ])

    assert [job] = String.split(jobs)

    assert {_, 0} =
             MachinePool.docker(pool, ["rename", job, "jido-example-recovered-" <> pool.tag])
  end

  defp git!(directory, args) do
    env = [
      {"GIT_DIR", nil},
      {"GIT_WORK_TREE", nil},
      {"GIT_COMMON_DIR", nil},
      {"GIT_INDEX_FILE", nil},
      {"GIT_OBJECT_DIRECTORY", nil},
      {"GIT_ALTERNATE_OBJECT_DIRECTORIES", nil},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"}
    ]

    assert {output, 0} =
             System.cmd("git", ["-C", directory | args], env: env, stderr_to_stdout: true)

    output
  end
end
