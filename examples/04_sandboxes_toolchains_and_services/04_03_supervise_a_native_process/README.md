# 04.03 Supervise a native process

Run an approved host tool with literal arguments and a working directory.
Use the same `Workspace.run/3`, `Workspace.output/3`, and
`Workspace.cancel/2` calls as the other command examples. The host
selects the process runner in a named profile.

## Configure the host

Add `{:erlexec, "~> 2.6"}` to the host application's dependencies.
erlexec builds a native helper. Workspace uses the POSIX shell's
`kill -0` to check the group. [erlexec installation and options](https://hexdocs.pm/erlexec/readme.html)

```elixir
config :jido_workspace,
  profiles: %{
    native: %{
      provider: :local,
      runner: :erlexec,
      policy: :full_access,
      tools: ["/bin/echo"],
      require: %{isolation: :process, cancellation: :process_group},
      store: "reports"
    }
  },
  stores: %{"reports" => "/var/lib/my_app/workspace"}
```

```elixir
alias Jido.Workspace

{:ok, workspace} = Workspace.open(profile: :native)
try do
  :ok = Workspace.mkdir(workspace, "build")

  {:ok, %{status: :exited, exit_status: 0, output: output}} =
    Workspace.run(workspace, ["/bin/echo", "report; draft"], cwd: "build")

  :ok = Workspace.write(workspace, "build/report.txt", output)
  {:ok, snapshot} = Workspace.save(workspace)
  snapshot
after
  :ok = Workspace.close(workspace)
end
```

The requirement checks the reported cancellation capability at open.
The default Port runner reports `:direct_child`. A profile that requires
`:process_group` must select erlexec. If Workspace cannot start erlexec,
open returns `:unsupported_capability`.

## Confirm that the group stopped

erlexec starts each command in its own process group and sends signals
to that group. Its exit report describes the leader. Workspace also
checks that the OS reports the group is gone before it accepts an exit
or cancel result. A native process that ignores `SIGTERM` can survive
its leader. If the check cannot confirm cleanup, run returns
`:quiescence_unknown`, and Workspace blocks writes and saves. Close
can return `:cleanup_unconfirmed` and keep the directory. The host can
stop the remaining process and retry close.

Use trusted tools that keep their writers in the original process group.
Local tools run with the host user's file and network access. A process
that starts a new session can leave the original group.
The OS can report that a group still exists until it reaps its exited
children. Workspace keeps the tree fenced while the group exists.

## Run the integration example

```sh
mix test examples/04_sandboxes_toolchains_and_services/04_03_supervise_a_native_process/example_test.exs \
  --include integration
```

The tests check fast stdout and stderr delivery, literal arguments,
working directory, and a nonzero exit status. A child announces that it
is ready before the test cancels the command. The test checks the actual
child PID before it saves the tree. A separate child ignores `SIGTERM`
and proves that Workspace keeps the tree fenced until cleanup.
[Integration tests](example_test.exs)

The public Workspace tests ran on macOS. A separate runner check in a
disposable Debian container confirmed fast output, exit status, and
cleanup of a child in the process group.
