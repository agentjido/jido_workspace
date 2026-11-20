# 02.03 Run an ordered batch

Use a list of file edits and argv commands when they must run in order on
one tree. The same list works on a memory or Docker profile.

```elixir
steps = [
  {:mkdir, "reports"},
  {:write, "reports/draft.txt", "Sales report\n"},
  {:run, ["cat", "draft.txt", "missing.txt"], [cwd: "reports"]},
  {:write, "reports/checked.txt", "Inputs checked\n"}
]

{:ok, %{status: :halted, results: [:ok, :ok], failure: %{index: 3, result: check}}} =
  Workspace.batch(workspace, steps)

{:ok, "Sales report\n"} = Workspace.read(workspace, "reports/draft.txt")
```

The report gives the completed results in order. The first failed step
appears under `failure` with its one-based index. Here `check` is the
execution with exit status 1 and the partial output. The draft remains.
Workspace skips the fourth step. If a command writes before it fails,
those changes can also remain.

Fix the input and decide which steps to repeat. The
[reader-facing example](example.ex) saves a successful batch on a
workspace with one application writer. Save is a separate call.

## Admission and lifecycle

Workspace validates the full step list before the first edit. A request
can contain up to 64 steps and use up to 4 MiB in Erlang external term
format. Workspace checks permissions and live file conditions as each
step starts.

Other tree calls return `:busy` during the batch. Use `Workspace.info/1`
to find the active execution ID, then use `Workspace.output/3` or
`Workspace.cancel/2` with that ID. Each new command replaces the
previous command's live output record. The report keeps the bounded
output of each finished command. A confirmed cancellation or timeout
halts the batch at that step. When Workspace cannot confirm that a
command or file write has stopped, it also blocks further writes and
saves.

After Workspace accepts close, the active step can finish. If steps
remain, the report names the first step that close prevented. The
close result confirms whether Workspace released the resources.

The host can set `batch_timeout_ms` and `batch_output_limit` in the profile
limits. The defaults are 60 seconds and 1 MiB. Each command uses the
remaining budget and its usual per-command limits. The deadline stops
admission of further steps. An admitted file operation, provider
startup, or cleanup can extend the wait.

## Run the tests

```sh
mix test examples/02_commands/02_03_run_an_ordered_batch/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/02_commands/02_03_run_an_ordered_batch/example_test.exs --include integration
```

The memory and Docker tests run the same report and output-limit cases.
The memory tests also hold the provider at a controlled point to check
close and an unconfirmed stop. A Docker test checks the write fence
after losing the controller during an edit. [Tests](example_test.exs)

## API fit and gaps

Plain tuples let callers compose a list with ordinary Elixir functions.
The command step uses the same options and result as `Workspace.run/3`.
The batch holds one tree through the final step. A caller that needs to
branch on intermediate results or publish the checked tree must
coordinate those separate calls.
