# 08.03 Verify and recover a deployment

Deploy an approved snapshot. Activate a candidate and make its verification fail. Inspect the failed check and the active release, then explicitly redeploy the approved snapshot to a new release directory.

## Save the two versions

Start IEx from the repository root with a temporary bundle store. This run uses a memory workspace and a local target. The tests also run the same workflow with a Docker workspace and a Docker target.

```sh
export WORKSPACE_RESULTS_DIR="$(mktemp -d)"
iex -S mix
```

```elixir
alias Jido.Workspace
alias Jido.Workspace.{Deploy, Sandbox}
alias Jido.Workspace.Deploy.{Artifact, Recipe, Snapshot}

Application.put_env(:jido_workspace, :stores, %{
  "reports" => System.fetch_env!("WORKSPACE_RESULTS_DIR")
})

Application.put_env(:jido_workspace, :profiles, %{
  author: %{provider: :memory, policy: :workspace_write, store: "reports"},
  reader: %{provider: :memory, policy: :read_only, store: "reports"}
})

verify = ~S"""
if [ "$(cat report.txt)" = "approved" ]; then
  printf 'verified\n'
else
  printf 'candidate rejected\n' >&2
  exit 7
fi
"""

{:ok, workspace} = Workspace.open(profile: :author)
:ok = Workspace.write(workspace, "verify.sh", verify)
:ok = Workspace.write(workspace, "report.txt", "approved\n")
{:ok, approved} = Workspace.save(workspace)
:ok = Workspace.write(workspace, "report.txt", "rejected\n")
{:ok, candidate} = Workspace.save(workspace)
:ok = Workspace.close(workspace)

artifact = fn reference, version ->
  {:ok, payload} = Snapshot.from_saved(reference, profile: :reader)
  {:ok, artifact} = Artifact.new(:source, version, payload)
  artifact
end

recipe = %Recipe{
  service: %{executable: "/bin/sleep", args: ["120"]},
  verify: {"/bin/sh", ["verify.sh"]}
}
```

The service is a short-lived fixture. The verify command checks the report in the active release. The sandbox separately reports whether the service is running.

## Inspect and recover

```elixir
{:ok, sandbox} = Sandbox.open(owner: self())

try do
  {:ok, target} = Deploy.source_target(sandbox, "report")
  {:ok, session} = Deploy.connect(target)

  run = fn plan ->
    {:ok, id} = Deploy.apply(session, plan)
    {:ok, record} = Deploy.await(session, id)
    record
  end

  accepted = artifact.(approved, "1")
  {:ok, plan} = Deploy.prepare(session, accepted, recipe: recipe)
  %{status: :succeeded, evidence: %{current: approved_release}} = run.(plan)

  {:ok, plan} = Deploy.prepare(session, artifact.(candidate, "2"), recipe: recipe)

  %{id: failed, status: :recovery_required, evidence: %{phase: :verify}} = run.(plan)
  {:ok, %{controller: %{blocked_by: ^failed}, identity: %{current: rejected_release}}} =
    Deploy.inspect(session)

  {:ok, "rejected\n"} =
    Sandbox.read(sandbox, Path.join([target.path, rejected_release, "report.txt"]))

  {:ok, ordinary} = Deploy.prepare(session, accepted, recipe: recipe)
  {:error, :recovery_required} = Deploy.apply(session, ordinary)

  {:ok, recovery} = Deploy.recover(session, failed, accepted, recipe: recipe)

  %{status: :succeeded, recovery_of: ^failed, snapshot_id: ^approved,
    evidence: %{current: restored_release, verification: [%{output: "verified\n"}]}} =
    run.(recovery)

  true = restored_release != approved_release
  {:ok, %{controller: %{blocked_by: nil}}} = Deploy.inspect(session)
  {:ok, %{status: :recovery_required}} = Deploy.status(session, failed)
after
  :ok = Sandbox.destroy(sandbox)
end
```

The operation record includes the failed command result, the phase, and target observations from before and after the attempt. The candidate stays active after verification fails. The host selects the recovery artifact and supplies its verify command. A failed recovery before activation preserves the original blocker. If recovery itself reaches an uncertain state, its operation becomes the new blocker.

The tests check restored snapshot contents, a fresh running service, and the stop of the rejected service. Recovery restarts processes and preserves records for the life of the deployment controller. Recovery of external state belongs to the host.

## Run the checks

```sh
mix test examples/08_deployment_and_application_workflows/08_03_verify_and_recover_a_deployment/example_test.exs --include integration
```

Set `JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20` to include Docker. Use a locally available image.
