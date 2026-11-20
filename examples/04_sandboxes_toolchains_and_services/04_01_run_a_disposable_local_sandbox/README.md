# 04.01 Run a disposable local sandbox

Use a named Local profile to run a trusted host executable in a new
workspace directory. Save the files you need before you close the
workspace. Close removes the directory and expires the handle.

Configure a snapshot store named `"reports"` and add a profile for the
copy command. [Snapshot store setup](../../README.md#save-and-reopen-after-a-beam-restart)

```elixir
config :jido_workspace,
  profiles: %{
    local_report: %{
      provider: :local,
      policy: [:read, :write, :execute, :save, :import],
      tools: ["/bin/cp"],
      require: %{isolation: :process},
      store: "reports"
    }
  }
```

Use literal arguments and paths relative to the current directory.
The example writes the input, runs `/bin/cp`, and saves the result
when the command exits successfully. [Copy and save](example.ex)

```elixir
alias Jido.Workspace
alias Jido.Workspace.Examples.DisposableSandbox

{:ok, workspace} = Workspace.open(profile: :local_report)

snapshot =
  try do
    {:ok, saved} = DisposableSandbox.copy_report(workspace, "Checked report\n")
    saved
  after
    :ok = Workspace.close(workspace)
  end

{:ok, restored} = Workspace.open(profile: :local_report, from: snapshot)
{:ok, "Checked report\n"} = Workspace.read(restored, "report.txt")
:ok = Workspace.close(restored)
```

## Select the provider in the profile

Local runs with the BEAM user's host files, environment, and network
access. The working directory gives a tool a place to start. Use
trusted tools and arguments that cannot leave a writer after exit or
interruption. The tool list matches the absolute executable path.
An executable Local profile must also grant write permission. Open
rejects a request for container isolation or disabled networking.

Local reports `cancellation: :direct_child`. On timeout or cancellation,
it waits for the port to report that the directly spawned process
exited. If it cannot confirm the stop, Workspace fences the tree.
Losing the port can leave the process alive. In that case, close returns
`:cleanup_unconfirmed` and leaves the root for the host.
The host is responsible for the behavior of any child that the tool
starts. Profiled Local commands use closed input and refuse input pipes.
[OTP port exit status](https://www.erlang.org/doc/apps/erts/erlang.html#open_port/2)

The same copy command works with a Docker profile and an installed Alpine
image. Set `provider: :docker` and
`require: %{isolation: :container, network: :disabled}` in that profile.
Docker provides its own filesystem and network boundary and stops the whole
container. Memory can reopen the saved file tree and use virtual tools.

Use `Workspace.close/1` for a profiled workspace. If the host uses the
lower-level Sandbox API, `Sandbox.destroy/1` releases the resources and
`Sandbox.close/1` leaves them available for `Sandbox.attach/1`.
[Sandbox ownership](../../../SANDBOX.md#ownership)

## Run the tests

```sh
mix test examples/04_sandboxes_toolchains_and_services/04_01_run_a_disposable_local_sandbox/example_test.exs \
  --include integration

JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/04_sandboxes_toolchains_and_services/04_01_run_a_disposable_local_sandbox/example_test.exs \
  --include integration
```

The tests check root removal, handle expiry, and restore of the saved
tree. They also check that a missing executable leaves the tree
available, that closed input gives end-of-file, and that a timed-out
Local process has exited before another write or save succeeds.
A fault test closes the port while that process is alive and verifies
the write fence and the unconfirmed close result. The Docker test
confirms the container is gone after close.
[Integration tests](example_test.exs)
