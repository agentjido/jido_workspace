# 02.05 Use an interactive session

Use `stdin: :pipe` to talk to a running command. The host can set
`require: %{stdin: :pipe}` in a Docker profile to check the capability
when Workspace opens. Memory refuses a pipe request before the command
starts.

[AnswerPrompt](example.ex) runs a program that prints a prompt, reads a
line, writes the reply to `name.txt`, and exits. Run the program in a
client process so another process can read and send bytes.

```elixir
alias Jido.Workspace
alias Jido.Workspace.Examples.AnswerPrompt

task = Task.async(fn -> AnswerPrompt.run(workspace) end)

# After Workspace admits the command, get its execution ID.
{:ok, %{active_execution_id: id}} = Workspace.info(workspace)

# Read until the prompt appears. Use the next offset for subsequent reads.
{:ok, %{bytes: "name?\n", next_offset: offset}} = Workspace.output(workspace, id)
:ok = AnswerPrompt.answer(workspace, id, "Ada")

{:ok, %{exit_status: 0}} = Task.await(task)
{:ok, %{bytes: "hello Ada\n", done?: true}} = Workspace.output(workspace, id, offset)
{:ok, "Ada\n"} = Workspace.read(workspace, "name.txt")
```

The tests wait for the execution ID and prompt with bounded waits.
See [Stream live output](../02_02_stream_live_output/README.md) for a stream
that reads each available slice. `Workspace.input/3` takes up to 16 KiB
per call. A reply of `:ok` means the transport accepted the bytes.
Read the program's output to confirm its response. Retry when the
pipe reports `:input_not_ready` or `:input_busy`.

## Stop or disconnect

`Workspace.cancel/2` stops new input immediately. Wait for the original
run result before editing or saving. On client disconnect, Workspace
requests a stop when the process that called `run/3` exits. Connect a
terminal or UI transport's disconnect to that process lifetime or call
`cancel/2` from the transport. Closing the workspace also requests a
stop for a command with a pipe.

Workspace blocks writes and saves until the provider confirms that the
command stopped. If confirmation fails, the tree stays fenced. If the
workspace stays open, the caller can inspect partial files after
confirmation. A snapshot is still a separate call.

## Run the tests

```sh
mix test examples/02_commands/02_05_use_an_interactive_session/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/02_commands/02_05_use_an_interactive_session/example_test.exs --include integration
```

Docker tests cover input before readiness, input and output during the
run, explicit cancellation, loss of the client process, and workspace
close. The disconnect test confirms removal of the container while the
workspace keeps a file that the command wrote earlier. The memory test
checks refusal and continued use of ordinary commands. [Tests](example_test.exs)

## API fit and gaps

A single execution ID controls the input pipe, output, and cancellation.
This example uses standard streams. Programs that require a terminal
need a PTY and terminal controls. Pipe input stays open until the
program exits or Workspace stops it. Batch steps use closed stdin.
