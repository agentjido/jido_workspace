# 02.04 Stop or time out a command

Run the command in a caller task when another process must be able to
stop it. Read `active_execution_id` with `Workspace.info/1` or from a
command start event. Pass that ID to `Workspace.cancel/2`.
[Command events](../../05_lifecycle/05_04_inspect_state/README.md)

```elixir
alias Jido.Workspace
alias Jido.Workspace.Examples.StopCommand

run = Task.async(fn ->
  Workspace.run(workspace, ["sleep", "30"], timeout_ms: 10_000, output_limit: 200)
end)

# After Workspace admits the command
{:ok, %{active_execution_id: id}} = Workspace.info(workspace)
result = StopCommand.cancel_and_wait(workspace, id, run, 500)
```

`Workspace.cancel/2` acknowledges the request. The tree stays busy while
the command stops. Wait for the original run result before requesting a
write or save. The example helper returns `{:pending, task}` when the
caller's wait expires. Use that task to observe the result later.
[Example](example.ex)

| Run result | What the caller knows |
| --- | --- |
| `{:ok, %{status: :cancelled}}` | Workspace confirmed the stop. The result includes captured output within the byte limit. |
| `{:ok, %{status: :timed_out}}` | The execution deadline expired and Workspace confirmed the stop. The result includes captured output within the byte limit. |
| `{:ok, %{status: :exited}}` | The command finished. Check the exit status. Completion can occur during the cancel request. |
| `{:error, %Workspace.Error{code: :quiescence_unknown}}` | Workspace could not confirm that writers stopped. It fences writes and saves. |

An ID from an earlier command returns `:execution_not_active`. A stopped
command can leave effects from before the stop. Review the tree before
save. If the result is `:quiescence_unknown`, keep the last known snapshot
and call `Workspace.close/2` to request resource release. Check its result.
[Close while work is running](../../05_lifecycle/05_02_race_close_with_work/README.md)

## Run the tests

```sh
mix test examples/02_commands/02_04_stop_or_time_out/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/02_commands/02_04_stop_or_time_out/example_test.exs --include integration
```

Memory checks stop requests between synchronous tool calls. The tests
keep the command output within a byte limit on cancellation and timeout.
They also block the worker past its confirmation wait and check the fence.
The Docker tests hold a child writer at a pipe, then verify removal of the
whole container and confirm that save succeeds. A separate test kills the
Docker controller while the child is active and checks the write fence.
[Tests](example_test.exs)

## API fit and gaps

Memory allows up to 1.25 seconds after a timeout or stop request for the
worker to reach a checkpoint. Docker uses container removal to confirm
the stop for the command and its children. These checks apply to the
local and disposable providers in this example. Releasing a remote
writer requires evidence from that provider.
