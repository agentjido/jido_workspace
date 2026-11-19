# Jido Workspace examples

The examples show how to use `jido_workspace`. Each core example has an
integration test for a result that the caller can observe.

Start with the [use-case matrix](table_of_contents.md#use-case-matrix). Each
row names a filesystem or storage role, an execution provider, a security
guarantee, and a lifecycle outcome. Choose combinations that test different
guarantees. Reuse a workflow across providers when the public contract is
the same.

## Start here

The [four core examples](00_core/README.md) use `Jido.Workspace` for files,
commands, access policy, and snapshots. The report workflow uses the same
calls on memory and Docker. The host selects the provider with a named
profile.

The [aspirational chapters](table_of_contents.md#aspirational-chapters) cover
working files, commands and streams, security, sandboxes, OTP lifecycle,
persistent providers, and deployment. Put the day-to-day workflow and its
security and recovery rules first. Save useful in-memory results to a
directory store. Git and S3 are optional examples for workflows that need
source history or object storage.

## Save and reopen after a BEAM restart

From the repository root, make a directory that both BEAM instances can
access. Keep the same terminal for both sessions.

```sh
export WORKSPACE_EXAMPLE_DIR="$(mktemp -d)"
iex -S mix
```

Paste this host configuration into each IEx session. Both profiles use the
same store ID and directory. The Docker profile needs a local Docker engine
and an installed `alpine:3.20` image.

```elixir
alias Jido.Workspace

root = System.fetch_env!("WORKSPACE_EXAMPLE_DIR")
reference_path = Path.join(root, "report.snapshot.json")

Application.put_env(:jido_workspace, :stores, %{"reports" => Path.join(root, "snapshots")})

Application.put_env(:jido_workspace, :profiles, %{
  memory: %{provider: :memory, policy: :full_access, store: "reports"},
  docker: %{
    provider: :docker,
    policy: :full_access,
    store: "reports",
    image: "alpine:3.20",
    require: %{isolation: :container, network: :disabled}
  }
})
```

In the first session, write the report and save the tree. Workspace writes
the file data to `snapshots/`. Keep the reference as a JSON file.

```elixir
{:ok, workspace} = Workspace.open(profile: :memory)
:ok = Workspace.write(workspace, "report.txt", "Report for today\n")
{:ok, snapshot} = Workspace.save(workspace)
:ok = File.write(reference_path, Jason.encode!(snapshot))
:ok = Workspace.close(workspace)
```

Exit IEx. Start a new `iex -S mix` in the same terminal and paste the host
configuration again. Read the reference and open the saved tree.

```elixir
snapshot = reference_path |> File.read!() |> Jason.decode!()
{:ok, workspace} = Workspace.open(profile: :memory, from: snapshot)
{:ok, "Report for today\n"} = Workspace.read(workspace, "report.txt")
:ok = Workspace.close(workspace)
```

To reopen the same tree on Docker, use `profile: :docker` in the open call.
Keep both the JSON reference and the snapshot store for as long as you need
to reopen the tree. The test runs the save and restore in separate BEAM
instances. [Restart test](00_core/00_04_restore_in_a_fresh_beam/example_test.exs)

## Use an example to shape the API

1. State the task and the result a caller can observe.
2. Try the workflow with the current public API and the smallest local fixture
   that can prove it. Use the same application calls in a provider-backed run.
3. Record where the API fits and where the example stalls. Include the
   failing call or missing guarantee. Use that evidence to propose the smallest
   public API change that lets the workflow complete.
4. Keep the example and its integration test together. Test the normal path
   and the failure, recovery, or cleanup behavior the example teaches. Use
   explicit synchronization and bounded waits for process and provider tests.

Each supported example has a `README.md`, reader-facing Elixir source,
and a colocated `*_test.exs` file tagged `:integration`. Add a `demo.exs` when
a standalone run helps. The README should state the visible result, exact test
command, setup, and limits of the proof. Advanced examples should add an
**API Fit and Gaps** section for missing operations, unclear ownership, and
code that more than one caller must write. Put test fixtures beside their
example. Keep private process state and test support out of the reader-facing
workflow.

## Local and provider-backed tests

The default examples should run offline with real Workspace processes,
temporary directories, and deterministic inputs. Use a local provider fixture
to test how Workspace handles provider replies and failures. Verify actual
containment, resource cleanup, and remote recovery with the provider that makes
those guarantees.

Keep real Docker, remote machines, and other external infrastructure opt-in.
Document the runtime, configuration, credentials, possible costs, timeout,
and cleanup. Use resources dedicated to the test. In a persistence example,
check that the machine survives Workspace close before the test harness
releases its own fixture.

## Run the core examples

From the repository root, run the numbered examples.

```sh
mix test.examples --warnings-as-errors
```

To also run the container examples, use a local Docker engine and an installed
Alpine image. The example does not pull the image.

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test.examples --warnings-as-errors
```

For a focused run, use the test command in the lesson README.
`mix test.integration` runs both the numbered examples and the existing
tests under `test/examples/`.
