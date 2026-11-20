# 02.01 Run a command with argv and cwd

Pass the tool and its arguments as a list to `Workspace.run/3`. Each
element is literal. Spaces and shell metacharacters in a filename stay
in that argument. Set `cwd:` to a directory relative to the workspace root.

```elixir
alias Jido.Workspace

directory = "monthly reports"
filename = "draft $(echo changed).txt"

:ok = Workspace.mkdir(workspace, directory)
:ok = Workspace.write(workspace, Path.join(directory, filename), "Approved report\n")

{:ok, execution} =
  Workspace.run(workspace, ["cat", filename, "missing.txt"],
    cwd: directory,
    output_limit: 1_024
  )

%{status: :exited, exit_status: 1, output: output} = execution
```

The command read the first file and failed to read the second. The
execution contains the bytes it read and the diagnostic, within the
output limit. For success, check both `status: :exited` and
`exit_status: 0`. Handle other execution results and API errors in the
caller. [Caller example](example.ex)

An invalid working directory causes an API error before the tool runs.
The same working directory check applies to memory and Docker. Use a
directory that already exists in the current tree.

## Run the tests

```sh
mix test examples/02_commands/02_01_run_argv_and_cwd/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/02_commands/02_01_run_argv_and_cwd/example_test.exs --include integration
```

Both providers read the literal filename from the requested directory
when another file with the same name exists at the root. Both retain
partial output on a nonzero exit, apply the byte limit, and return an
error for a missing directory or a file used as `cwd`. Both can save
after these failures. [Tests](example_test.exs)

## API fit and gaps

The result shape is shared. Memory reports exit status `1` for a
completed virtual tool failure. Docker reports the process exit status.
Tool syntax, diagnostic text, and output order can vary by provider.
Use the exit status and truncation flag in portable callers.
