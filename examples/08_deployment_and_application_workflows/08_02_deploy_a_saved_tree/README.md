# 08.02 Deploy a saved tree

Save a tree, change the live files, then deploy the earlier version to a separate target. The deployment record identifies the exact saved reference. The target keeps the saved bytes, executable files, and empty directories.

## Configure the store and profiles

Start IEx from the repository root. Give the example its own directory for saved bundles.

```sh
export WORKSPACE_RESULTS_DIR="$(mktemp -d)"
iex -S mix
```

```elixir
results = System.fetch_env!("WORKSPACE_RESULTS_DIR")
store = Path.join(results, "bundles")
Application.put_env(:jido_workspace, :stores, %{"reports" => store})
Application.put_env(:jido_workspace, :profiles, %{
  author: %{provider: :memory, policy: :workspace_write, store: "reports"},
  reader: %{provider: :memory, policy: :read_only, store: "reports"}
})
```

## Save and hand off the reference

```elixir
alias Jido.Workspace

{:ok, workspace} = Workspace.open(profile: :author)
:ok = Workspace.mkdir(workspace, "reports")
:ok = Workspace.mkdir(workspace, "reports/empty")
:ok = Workspace.write(workspace, "reports/final.txt", "approved report\n")
{:ok, saved} = Workspace.save(workspace)
:ok = File.write(Path.join(results, "saved.json"), Jason.encode!(saved))

:ok = Workspace.write(workspace, "reports/final.txt", "later draft\n")
:ok = Workspace.delete(workspace, "reports/empty")
:ok = Workspace.close(workspace)
```

You can stop IEx after this step. To deploy from a new BEAM, keep `WORKSPACE_RESULTS_DIR` and run the configuration again. The reader profile must grant `:read` and `:import` for the saved reference's store. The deploy step reads the bundle directly and uses only the target sandbox to stage files or run checks.

## Deploy to a separate target

```elixir
alias Jido.Workspace.{Deploy, Sandbox}
alias Jido.Workspace.Deploy.{Artifact, Snapshot}

reference = results |> Path.join("saved.json") |> File.read!() |> Jason.decode!()
{:ok, saved} = Jido.Workspace.Snapshot.parse(reference)
{:ok, payload} = Snapshot.from_saved(reference, profile: :reader)
{:ok, artifact} = Artifact.new(:source, "report-1", payload)
{:ok, sandbox} = Sandbox.open(owner: self())

try do
  {:ok, target} = Deploy.source_target(sandbox, "report")
  {:ok, session} = Deploy.connect(target)
  {:ok, plan} = Deploy.prepare(session, artifact)
  {:ok, operation_id} = Deploy.apply(session, plan)

  {:ok, %{status: :succeeded, snapshot_id: ^saved, evidence: %{current: current}}} =
    Deploy.await(session, operation_id)

  release = Path.join(target.path, current)
  {:ok, "approved report\n"} = Sandbox.read(sandbox, Path.join(release, "reports/final.txt"))
  :ok = Snapshot.verify(payload, Path.join(sandbox.root, release))
after
  :ok = Sandbox.destroy(sandbox)
end
```

The saved reference identifies the bundle. The deploy payload has its own digest for the file paths, bytes, modes, and directory paths. Deploy stages a release directory and checks those entries before it switches the target's `current` link. If preparation removes or renames a saved entry, the previous release stays active.

## Run the checks

```sh
mix test examples/08_deployment_and_application_workflows/08_02_deploy_a_saved_tree/example_test.exs --include integration
```

Set `JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20` to also save a Docker workspace and run its saved executable in a separate Docker target. Use a locally available image.
