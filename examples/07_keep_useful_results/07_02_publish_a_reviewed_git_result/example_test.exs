Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.PublishReviewedGitTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.Examples.{LifecycleSupport, PublishReviewedGit}

  @branch "refs/heads/reviewed"

  setup %{tmp_dir: root} do
    LifecycleSupport.configure(Path.join(root, "snapshots"))
    %{memory: memory, docker: docker} = Application.fetch_env!(:jido_workspace, :profiles)

    Application.put_env(:jido_workspace, :profiles, %{
      scratch: %{memory | policy: [:read, :write, :save]},
      review: %{memory | policy: :read_only},
      docker_review: %{docker | policy: :read_only}
    })

    checkout = Path.join(root, "checkout")
    repo = Path.join(root, "results.git")
    File.mkdir!(checkout)
    git!(checkout, ["init", "--template=", "--initial-branch=reviewed"])
    File.write!(Path.join(checkout, "README.md"), "Original tree\n")
    File.write!(Path.join(checkout, "report.txt"), "Previous report\n")
    git!(checkout, ["add", "--", "README.md", "report.txt"])

    git!(checkout, [
      "-c",
      "user.name=Workspace Example",
      "-c",
      "user.email=workspace@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-m",
      "Set up the target branch"
    ])

    git!(root, ["clone", "--bare", "--no-hardlinks", "--template=", checkout, repo])
    git!(repo, ["config", "user.name", "Workspace Example"])
    git!(repo, ["config", "user.email", "workspace@example.invalid"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    git!(repo, ["config", "core.hooksPath", Path.join(root, "empty-hooks")])

    %{repo: repo, base: head(repo), checkout: checkout}
  end

  test "publishes the selected bytes from a saved memory tree", %{repo: repo, base: base} do
    verify_review(:review, repo, base)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to review the same saved tree on Docker"
  end

  test "publishes through the same Workspace API when review runs on Docker", %{
    repo: repo,
    base: base
  } do
    verify_review(:docker_review, repo, base)
  end

  test "two prepared results compete for the same branch head", %{repo: repo, base: base} do
    first = "First candidate\n"
    second = "Second candidate\n"
    assert {:ok, pending} = prepare(:review, repo, base, save_candidate(first))
    assert {:ok, winner} = prepare(:review, repo, base, save_candidate(second))
    assert head(repo) == base

    assert {:ok, commit} = PublishReviewedGit.publish(repo, winner)
    assert {:error, :target_changed} = PublishReviewedGit.publish(repo, pending)
    assert head(repo) == commit
    assert git!(repo, ["show", "#{@branch}:report.txt"]) == second

    reference = save_candidate(first)
    assert {:error, :target_changed} = prepare(:review, repo, base, reference)
    assert {:ok, revised} = prepare(:review, repo, commit, reference)
    assert {:ok, new_head} = PublishReviewedGit.publish(repo, revised)
    assert git!(repo, ["show", "#{new_head}:report.txt"]) == first
    assert String.trim(git!(repo, ["rev-parse", "#{new_head}^"])) == commit
  end

  test "refuses to publish directly to a checkout", %{checkout: checkout, base: base} do
    reference = save_candidate("Candidate\n")

    assert {:error, :bare_repository_required} =
             prepare(:review, Path.join(checkout, ".git"), base, reference)

    assert head(checkout) == base
  end

  defp verify_review(profile, repo, base) do
    report = <<"Reviewed report\r\n", 0, 255>>
    reference = save_candidate(report)
    assert {:ok, prepared} = prepare(profile, repo, base, reference)
    assert head(repo) == base
    assert {:ok, commit} = PublishReviewedGit.publish(repo, prepared)

    assert head(repo) == commit
    assert String.trim(git!(repo, ["rev-parse", "#{commit}^"])) == base

    assert git!(repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", commit]) ==
             "report.txt\n"

    assert git!(repo, ["show", "#{commit}:report.txt"]) == report
    assert git!(repo, ["show", "#{commit}:README.md"]) == "Original tree\n"
    refute File.exists?(Path.join(repo, "index"))
  end

  defp save_candidate(report) do
    assert {:ok, workspace} = Workspace.open(profile: :scratch)

    try do
      assert :ok = Workspace.write(workspace, "report.txt", report)
      assert :ok = Workspace.write(workspace, "draft.txt", "Private notes\n")
      assert {:ok, snapshot} = Workspace.save(workspace)
      assert :ok = Workspace.write(workspace, "report.txt", "Unreviewed edit\n")
      snapshot |> Jason.encode!() |> Jason.decode!()
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp prepare(profile, repo, base, reference) do
    assert {:ok, review} = Workspace.open(profile: profile, from: reference)

    report =
      try do
        assert {:ok, contents} = Workspace.read(review, "report.txt")
        contents
      after
        assert :ok = Workspace.close(review)
      end

    PublishReviewedGit.prepare(repo, base, report)
  end

  defp head(repo), do: repo |> git!(["rev-parse", @branch]) |> String.trim()

  defp git!(repo, args) do
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

    assert {output, 0} = System.cmd("git", ["-C", repo | args], env: env, stderr_to_stdout: true)
    output
  end
end
