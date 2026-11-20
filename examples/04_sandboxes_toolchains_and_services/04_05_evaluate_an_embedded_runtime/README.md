# 04.05 Evaluate an embedded runtime

Run Lua in the BEAM on a memory workspace. The script reads a draft
and writes the same report as the pinned Python example. It takes a
script path and literal arguments. Both runs use `Workspace.run/3`
with a relative working directory.
[Pinned Python toolchain](../04_04_use_a_pinned_language_toolchain/README.md)

## Select a memory profile

```elixir
config :jido_workspace,
  profiles: %{
    lua_report: %{
      provider: :memory,
      policy: :full_access,
      tools: ["lua"],
      require: %{isolation: :mediated, network: :disabled},
      store: "reports"
    }
  },
  stores: %{"reports" => "/var/lib/my_app/workspace"}
```

The host must list `"lua"` explicitly. The profile must grant read,
write, and execute permissions for this command.

## Generate a report

Copy the [Lua program](report.lua) into the working tree. Workspace sets
`arg[0]` to the script name and passes command arguments as
`arg[1]`, `arg[2]`, and subsequent entries. The script and both file
functions resolve their paths from the command's working directory.

```elixir
alias Jido.Workspace

program =
  File.read!(
    "examples/04_sandboxes_toolchains_and_services/04_05_evaluate_an_embedded_runtime/report.lua"
  )

{:ok, workspace} = Workspace.open(profile: :lua_report)

snapshot =
  try do
    :ok = Workspace.mkdir(workspace, "build")
    :ok = Workspace.write(workspace, "build/report.lua", program)
    :ok = Workspace.write(workspace, "build/draft; Q4.txt", "quarterly report\n")

    {:ok, %{status: :exited, exit_status: 0, output: "Lua 5.3\n"}} =
      Workspace.run(workspace, ["lua", "report.lua", "draft; Q4.txt", "report.txt"],
        cwd: "build",
        timeout_ms: 1_000
      )

    {:ok, "QUARTERLY REPORT\n"} = Workspace.read(workspace, "build/report.txt")
    {:ok, snapshot} = Workspace.save(workspace)
    snapshot
  after
    :ok = Workspace.close(workspace)
  end
```

## Compare the execution boundaries

| Behavior | Embedded Lua on memory | Python on Docker |
| --- | --- | --- |
| File access | `workspace.read(path)` and `workspace.write(path, bytes)` use relative paths. Lua can read its own staged bytes. | Python uses its standard file APIs on the mounted tree. |
| Incomplete execution | A script error or a stop during evaluation discards the staged writes. Workspace publishes the files together after a successful evaluation. | Writes to the mounted tree can survive a command failure or a confirmed stop. |
| Interruption | Cancel or timeout stops the BEAM worker during evaluation. The original run returns the confirmed status. | The Docker provider confirms that the command container has stopped. |
| Isolation | Lua shares the BEAM. Workspace controls the exposed file functions, removes the OS, I/O, package, and debug libraries, and keeps dynamic loaders disabled. | The tool runs in a separate container with a read-only root and disabled networking. |

The Lua worker has a wall-clock deadline and per-run limits. It can
stage up to 128 files and 1 MiB of file data. The script and each file
read have a 1 MiB limit. Lua also applies limits to strings and call
depth. The BEAM checks the worker's heap during garbage collection.
[Lua sandbox and resource limits](https://lua.hexdocs.pm/sandboxing-1.html)

Cancellation during evaluation discards the staged files. If publication
has already started, it can finish as a single write operation. Wait for
the original run result before you save or start another command.

## Run the integration tests

```sh
mix test examples/04_sandboxes_toolchains_and_services/04_05_evaluate_an_embedded_runtime/example_test.exs \
  --include integration
```

The tests verify the report and restore it from a snapshot. They confirm
that the VM refuses a real host fixture and parent traversal. They also
check the write policy, cancellation at an output checkpoint, a loop
timeout, bounded output, the draft size limit, and a failed publication.
The isolation tests cover these interfaces in the embedded VM. Use the
Docker example for a separate OS isolation boundary.
[Integration tests](example_test.exs)
