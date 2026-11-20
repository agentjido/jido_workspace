# 02.02 Stream live output

Run the command while a second process reads its output. Pass
`notify_start: {reader_pid, reference}` to `Workspace.run/3` to send the
reader `{:workspace_command_started, reference, execution_id}` on
admission. Use the ID even if the command finishes before the first
read. A command refused before admission sends no notice. Use the run
result to resolve that case.
[Build and review](../../08_deployment_and_application_workflows/08_01_build_test_review_and_hand_off/README.md)

You can also get the active ID with `Workspace.info/1` or observe the
command start event.
[Command events](../../05_lifecycle/05_04_inspect_state/README.md)

```elixir
{:ok, slice} = Workspace.output(workspace, execution_id, 0)
{:ok, next_slice} = Workspace.output(workspace, execution_id, slice.next_offset)
```

Each observer uses its own byte offset. The read returns the available
bytes, the next offset, and the number of bytes that fell out of the
window. For example, when the command has emitted 16 bytes and the
limit is 4, a read at offset 4 reports 8 dropped bytes and returns the
last 4 bytes. The next read starts at offset 16.

Use [the example stream](example.ex) to read slices until the controller
settles the command. The stream waits briefly between empty reads.

```elixir
alias Jido.Workspace.Examples.FollowOutput

workspace
|> FollowOutput.follow(execution_id)
|> Enum.each(&IO.inspect/1)
```

The window combines standard output and standard error as the provider
delivers them. The effective command output limit bounds its size. The
returned `Execution.output` stores the first bytes within the same limit.
Use the original run result to check the exit or stop outcome. A slice
with `done?: true` means that the output record is final, including when
Workspace could not confirm that writers stopped. The record is available
until the next admitted command or workspace close.

## Run the tests

```sh
mix test examples/02_commands/02_02_stream_live_output/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/02_commands/02_02_stream_live_output/example_test.exs --include integration
```

The memory tests read before cancellation and check a zero-byte window.
The Docker test stops the command at two pipes to check independent
observers, a gap, and the final bytes at exact offsets. A related test
checks that the last bytes are available after loss of the Docker
controller while the workspace stays fenced.
[Stop or time out a command](../02_04_stop_or_time_out/README.md)

## API fit and gaps

The same read call works on memory and Docker. A slow reader can miss
bytes while the command continues. A caller that needs to keep the
output must read it in time and store it before the next command starts.
