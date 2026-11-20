# Authorize by operation

Give each role the permissions it needs. These profiles open separate
disposable copies of the same saved report.

| Profile | Read | Edit | Execute | Import | Save |
| --- | --- | --- | --- | --- | --- |
| `:editor` | Yes | Yes | | Yes | |
| `:inspector` | Yes | | Yes | Yes | |
| `:builder` | Yes | Yes | Yes | Yes | |
| `:publisher` | Yes | | | Yes | Yes |

The host assigns the profiles. Start with an existing `snapshot` from the
`"reports"` store. Configure it as shown in the
[examples guide](../../README.md#save-and-reopen-after-a-beam-restart).

```elixir
alias Jido.Workspace
alias Jido.Workspace.Snapshot

{:ok, snapshot} = Snapshot.parse(snapshot)
runner = %{provider: :memory, store: "reports"}

Application.put_env(:jido_workspace, :profiles, %{
  editor: Map.put(runner, :policy, [:import, :read, :write]),
  inspector: Map.put(runner, :policy, [:import, :read, :execute]),
  builder: Map.put(runner, :policy, [:import, :read, :write, :execute]),
  publisher: Map.put(runner, :policy, [:import, :read, :save])
})

{:ok, workspace} = Workspace.open(profile: :inspector, from: snapshot)
{:ok, %{exit_status: 0, output: report}} = Workspace.run(workspace, ["cat", "report.txt"])
{:error, %Workspace.Error{code: :policy_denied, details: %{action: :write}}} =
  Workspace.write(workspace, "report.txt", "An edit")
:ok = Workspace.close(workspace)

{:ok, workspace} = Workspace.open(profile: :publisher, from: snapshot)
{:ok, ^snapshot} = Workspace.save(workspace)
:ok = Workspace.close(workspace)
```

Use `%{provider: :docker, image: "alpine:3.20", store: "reports"}` for
`runner` to run the same calls on Docker. Install the image before running
the example.

Execution requires `:read`. If `:write` is absent, the memory runner
refuses virtual tools that can edit files. Docker starts the command with
a read-only mount of the tree and excludes submounts. A Docker command
that tries to write the mounted tree can return an execution with a nonzero
exit status. A Workspace permission check returns a `:policy_denied` error
with its denied action. The host must still choose the profiles and control
which callers receive their handles.

Each imported copy belongs to its own open workspace. An editor that needs to
hand off new work must have an approved way to save it. The publisher in
this example checks and saves the existing report. The Docker test also
saves a new snapshot from a host checkout and opens it on memory.
See [the example code](example.ex) and [the integration test](example_test.exs).

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/03_security_and_policy/03_01_authorize_by_operation/example_test.exs \
  --include integration
```
