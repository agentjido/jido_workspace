# 06.01 Add a provider through public callbacks

Bind a file tree and a command runner to one lease. Select them through
a named profile and use the same Workspace calls as on memory and Docker.
The example provider wraps a memory tree and implements a literal
`copy` command over that tree. It has no dependency on the Jido runtime.

## Select the provider

The host supplies the provider module and its options. This fixture
uses a local Agent as its allocation registry. A host application
can supervise that registry and give it to the provider.

```elixir
Code.require_file(
  "examples/06_providers_and_persistent_infrastructure/06_01_add_a_provider/report_provider.ex"
)

alias Jido.Workspace
alias Jido.Workspace.Examples.ReportProvider

{:ok, registry} = ReportProvider.start_link([])

Application.put_env(:jido_workspace, :profiles, %{
  report: %{
    provider: {ReportProvider, %{registry: registry}},
    policy: :full_access,
    require: %{isolation: :mediated, network: :disabled, cancellation: :cooperative},
    tools: ["copy"],
    store: "reports"
  }
})

Application.put_env(:jido_workspace, :stores, %{
  "reports" => Path.join(System.tmp_dir!(), "jido-reports")
})
```

## Work on the tree

```elixir
{:ok, workspace} = Workspace.open(profile: :report)

snapshot =
  try do
    {:ok, %{capabilities: %{provider: ReportProvider, tree_access: :read_write}}} =
      Workspace.info(workspace)

    :ok = Workspace.mkdir(workspace, "build")
    :ok = Workspace.write(workspace, "build/draft; Q4", "quarterly report\n")

    {:ok, %{status: :exited, exit_status: 0}} =
      Workspace.run(workspace, ["copy", "draft; Q4", "report.txt"], cwd: "build")

    {:ok, snapshot} = Workspace.save(workspace)
    snapshot
  after
    :ok = Workspace.close(workspace)
  end

{:ok, restored} = Workspace.open(profile: :report, from: snapshot)

try do
  {:ok, "quarterly report\n"} = Workspace.read(restored, "build/report.txt")
after
  :ok = Workspace.close(restored)
end
```

## Implement the boundary

| Callback | Responsibility |
| --- | --- |
| `provision/3` | Receive a lease ID before allocating. Install the optional capture. Return the live environment and its enforced capabilities. |
| `file/2` | Operate on relative paths in that tree. Check the expected revision in the same operation as a conditional write. |
| `run/2` | Use that tree and the requested working directory. Accept literal argv, emit output, and check the stop signal. Confirm that writers have stopped before returning a settled result. |
| `capture/2` | Return a quiescent capture within the entry and byte limits. Workspace publishes it to the profile's store. |
| `release/2` | Revoke the lease ID, stop or fence its writers, and release its session resources. Handle a partial allocation, a pending provision, and repeated release. |

The live environment can contain provider handles. The snapshot is a
durable reference to files. The host retains durable infrastructure and
command identities when a provider supports them.

Workspace compares the capability report with the profile requirements
and the requested read or write access before it returns a handle. The
example proves mediated execution and cooperative cancellation. A
container isolation requirement fails and triggers lease release.
Workspace trusts the host module to implement the guarantees it reports.

Each lease has a cleanup process that can act while provision is blocked.
On open timeout, opener exit, or controller loss, it calls `release/2`
by lease ID. Release must still work if provision has not returned.
The example registry records revoked IDs so it can refuse a late
allocation. A failed release keeps cleanup unconfirmed and can be
retried. A close call can read the confirmation after the controller
has exited.

The command callback can return `:quiescence_unknown` when it cannot
confirm the state of a writer. Workspace then blocks further writes
and saves. Close the handle and wait for confirmed release. Recovery
after a full BEAM stop requires evidence from the infrastructure provider.
This example verifies the lifecycle while the BEAM stays available.

The fixture implements the file operations used by the example.
It reports an unsupported operation for move and delete. Workspace's
custom callback contract supports command output and cancellation.
Use a built-in Docker profile for input pipes and loopback connections.

## Run the integration tests

```sh
mix test examples/06_providers_and_persistent_infrastructure/06_01_add_a_provider/example_test.exs \
  --include integration
```

The tests check shared file and command access, read-only enforcement,
bounded output, and snapshot restore on the provider and on memory.
They also prove release after capability rejection or a callback crash,
revocation before a late allocation, cleanup after controller loss, and
the write fence after an unknown command result.
[Provider implementation](report_provider.ex) · [Integration tests](example_test.exs)
