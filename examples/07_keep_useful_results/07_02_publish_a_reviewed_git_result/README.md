# 07.02 Publish a reviewed Git result

Save a candidate from a scratch workspace. Review the saved tree and put
the approved `report.txt` on a Git branch. The example uses a dedicated
local bare repository. The host owns the repository, commit identity,
and approval decision.

## Set up a local Git repository

Make a dedicated local Git fixture in the terminal where you will start
IEx. The bare repository needs an existing `reviewed` branch and a
configured author name and email.

```sh
git_dir=$(mktemp -d)
git init --bare --initial-branch=reviewed "$git_dir/results.git"
git -C "$git_dir/results.git" config user.name 'Workspace Example'
git -C "$git_dir/results.git" config user.email workspace@example.invalid
git -C "$git_dir/results.git" config commit.gpgsign false
empty_tree=$(git -C "$git_dir/results.git" write-tree)
base=$(git -C "$git_dir/results.git" commit-tree "$empty_tree" -m 'Set up the target branch')
git -C "$git_dir/results.git" update-ref refs/heads/reviewed "$base"
export WORKSPACE_RESULTS_GIT="$git_dir/results.git"
export WORKSPACE_RESULTS_BASE="$base"
```

## Read the approved result

Follow [07.01](../07_01_save_a_scratch_tree_to_disk/README.md) to save a
candidate and record its approved JSON reference. The `:review` profile
must have read-only access and use the same store as the scratch profile.
The test also uses a read-only Docker profile with that store.

```elixir
alias Jido.Workspace

reference = Jason.decode!(approved_reference)
{:ok, review} = Workspace.open(profile: :review, from: reference)

report =
  try do
    {:ok, contents} = Workspace.read(review, "report.txt")
    contents
  after
    :ok = Workspace.close(review)
  end
```

## Prepare and publish a commit

Run this code in IEx from the Jido Workspace repository root. Use the
full commit ID the host recorded for `refs/heads/reviewed` at review
time as `expected_head`.

```elixir
Code.require_file("examples/07_keep_useful_results/07_02_publish_a_reviewed_git_result/example.ex")
alias Jido.Workspace.Examples.PublishReviewedGit

repo = System.fetch_env!("WORKSPACE_RESULTS_GIT")
expected_head = System.fetch_env!("WORKSPACE_RESULTS_BASE")
{:ok, prepared} = PublishReviewedGit.prepare(repo, expected_head, report)
{:ok, commit} = PublishReviewedGit.publish(repo, prepared)
IO.puts(commit)
```

Preparation copies the base tree into a private Git index. It adds the
exact report bytes as a regular file and creates a commit with the
expected head as its parent. Keep the snapshot reference to reopen the
reviewed workspace. Keep the commit ID to find the published report in
Git. The other files in the snapshot stay in the snapshot store.

Publication compares and updates the branch in one Git operation. If the
head has changed, publication returns `{:error, :target_changed}` and
keeps the newer head. Review the report against that head before you
prepare a replacement commit. If you lose the result of publication,
inspect the branch and its history for the prepared commit before you
retry. Git can remove unreferenced objects after its retention period.

## Run the integration tests

```sh
mix test examples/07_keep_useful_results/07_02_publish_a_reviewed_git_result/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/07_keep_useful_results/07_02_publish_a_reviewed_git_result/example_test.exs \
  --include integration
```

The tests check exact byte content, preservation of the base tree, and
refusal when two commits compete for the same branch head. They reopen
the same kind of saved reference on memory and Docker. They use local Git
repositories. Remote push and branch protection are host concerns.
[Example code](example.ex) · [Tests](example_test.exs)
