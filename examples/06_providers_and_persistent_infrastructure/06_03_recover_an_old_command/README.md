# 06.03 Recover an old command

Record the command reference before launch. If the launch reply is lost
or the Workspace BEAM stops, use the reference to inspect, wait for,
or stop the command. Keep the original machine.

## Launch and recover

The host configures a persistent provider with command recovery support.
In this example, `:run` has permissions to edit and execute. `:recovery`
has only `[:recover]`. Both profiles use the same host provider and
infrastructure namespace.

Before launch, create a reference from the host's machine reference and a
new command ID. Persist the reference where a fresh BEAM can read it.

```elixir
alias Jido.Workspace
alias Jido.Workspace.CommandRef

command_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
{:ok, command} = CommandRef.new(machine, command_id)
:ok = File.write!(command_path, Jason.encode!(command))
{:ok, workspace} = Workspace.open(profile: :run, infrastructure: machine)

Workspace.run(workspace, ["write-report"], command: command)
```

The example tests use fixed IDs on dedicated machines.

In a fresh BEAM with the same host configuration, load the command
reference. There is no need to open a workspace to recover it.

```elixir
command = command_path |> File.read!() |> Jason.decode!()

Workspace.recover_command(:recovery, command, :inspect)
Workspace.recover_command(:recovery, command, :wait, timeout_ms: 1_000)

# Use this only when the host chooses to stop the command.
Workspace.recover_command(:recovery, command, :stop)
```

- A known active command returns `%{status: :running, exit_status: nil}`.
  The provider can return this from a bounded wait if the command is
  still running at its last check.
- A confirmed exit returns `%{status: :exited, exit_status: code}`. Stop
  waits for confirmation. A repeat stop returns the same exit state.
- If the provider cannot confirm the outcome, recovery returns
  `:quiescence_unknown`. Query the same reference again. An unrecognized
  reference gives `:command_not_found` when the provider can confirm it.
- A provider refuses a launch with an already used reference. The
  recovery call and the run call have separate results. A recovered exit
  gives the exit code that the provider observed.

## API fit and gaps

The live execution ID is for streaming and cancelling work within an
open workspace. The durable command reference identifies work at the
provider after the Workspace process is gone. Write and save stay fenced
after a launch with an unknown outcome. Confirming one command exited
leaves the provider responsible for revoking the old lease and checking
all of its writers before admitting another. See
[06.04 Block a stale writer](../06_04_block_a_stale_writer/README.md)
for the two checks and the replacement workflow.

The local test host holds the lease and command records in a separate
BEAM. It runs each job in its own short-lived container on the same
local Docker engine, with a mount of the retained machine's tree. The
job has a fixed tool, disabled networking, and no published ports. The
provider test endpoint listens on loopback with a fixture token. The
test suite removes the containers with its own pool label.

This proves recovery across Workspace BEAM loss while the host service
and engine remain available. A provider for a real fleet must keep its
command records across the failures it claims to handle. The example
uses an installed local image and requires no remote account.

## Run the integration tests

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/06_providers_and_persistent_infrastructure/06_03_recover_an_old_command/example_test.exs \
  --include integration
```

The tests drop a launch reply after Docker starts the job. They also
stop a Workspace BEAM with `System.halt/1` and use another BEAM to
recover and stop the surviving job. The fixture keeps the original
machine and its start time. Tests without Docker cover reference
validation, recovery policy, capability checks, and uncertain outcomes.
[Tests](example_test.exs) · [Recovery provider](recovery_provider.ex) · [Host service](recovery_host.ex)
