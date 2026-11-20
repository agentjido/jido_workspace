# 05.04 Inspect workspace and command state

Use `Workspace.info/1` to inspect a profiled workspace. It reports the
current phase and the ID of a command while it is active. The same ID
identifies the result and the command events. Read-only profiles can
inspect workspace status.

```elixir
alias Jido.Workspace

{:ok, %{id: workspace_id, phase: phase, active_execution_id: execution_id}} =
  Workspace.info(workspace)
```

The phases are `:ready`, `:running`, `:saving`, `:closing`, and
`:quiescence_unknown`. If Workspace cannot confirm that writers have
stopped, it reports `:quiescence_unknown` and refuses writes and saves.
An expired handle returns `:closed`.

## Match results to events

Attach the example handler before the command. It forwards events with
the workspace ID to the caller. Use a unique workspace ID when you
observe multiple workspaces. Detach the handler when observation ends.
[Example handler](example.ex)

```elixir
alias Jido.Workspace.Examples.ObserveCommand

{:ok, handler} = ObserveCommand.attach(workspace)

try do
  {:ok, execution} = Workspace.run(workspace, ["cat", "report.txt"], output_limit: 200)
  id = execution.id

  receive do
    {:workspace_command, :stop, %{duration_ms: duration}, %{execution_id: ^id} = outcome} ->
      {execution.output, duration, outcome}
  end
after
  :telemetry.detach(handler)
end
```

For each admitted command, Workspace emits the following Telemetry events.

| Event | Measurement | Metadata |
| --- | --- | --- |
| `[:jido_workspace, :command, :start]` | `system_time` in native time units | `workspace_id` and `execution_id` |
| `[:jido_workspace, :command, :stop]` | `duration_ms` | Both IDs. The status and exit status for a command result, or `status: :error` and `error_code` for an operation error. |

Use `execution.id` on success and `error.details.execution_id` on an error
after admission. A command can exit with a nonzero status and still return
a result with output. Refused requests have no execution ID.

Keep handlers short. They run in the workspace controller. Send the event
to another process for further work, including calls to `Workspace.info/1`.
Telemetry is available to trusted code in the same BEAM. Event metadata
excludes command arguments, file paths, output, and detailed errors.

## Run the tests

```sh
mix test examples/05_lifecycle/05_04_inspect_state/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/05_lifecycle/05_04_inspect_state/example_test.exs --include integration
```

Both providers match a running command to its bounded result. Both report
a missing working directory with the same error code, and both let a
read-only caller check status. The Docker command exits nonzero. The
memory tests also stop a worker and verify the status and write fence.
[Tests](example_test.exs)

## API fit and gaps

The same status and events work across profiles. Keep the execution ID
for correlation within this lifetime. A controller crash can end event
delivery before a stop event. Live output and command recovery need
their own contracts.
