# 06.05 Hand off to an external maintainer

Give a maintainer exclusive write access to a persistent tree. Return
the tree to Workspace after the provider confirms that the console and
all its processes have stopped.

## Hand off the writer slot

Use the provider fixture from
[06.03 Recover an old command](../06_03_recover_an_old_command/README.md).
The host runs a dedicated Docker console with write access to the
machine's tree. It uses the same writer slot as a Workspace lease. The
host owns the engine credentials. The maintainer submits commands
through the host's console connection.

Close the Workspace and confirm release before starting the console.
If the original Workspace is unavailable, use
[06.04 Block a stale writer](../06_04_block_a_stale_writer/README.md)
to revoke its lease and confirm that its writers stopped. The provider
refuses the handoff while that check is pending.

```elixir
alias Jido.Workspace
alias Jido.Workspace.Examples.{MachinePool, RecoveryHost}

:ok = Workspace.close(workspace)
request_id = "review-release-42"
{:ok, console} = RecoveryHost.begin_maintenance(host, machine, request_id)

:ok =
  RecoveryHost.run_maintenance(host, machine, request_id, [
    "/bin/sh",
    "-eu",
    "-c",
    ~S(printf '%s\n' "$1" > review.txt),
    "review",
    "approved"
  ])
```

The console command starts a separate process. Wait for the maintainer
to confirm that the review file is ready before you return the tree.
If the begin reply is lost, use the same request ID to find the console.

## Return the tree

The first end request bars new console commands. An active console
returns `:cleanup_unconfirmed` and still holds the writer slot. In this
fixture the host then stops the exact console container. It checks that
the container has exited and removes it before it releases the slot.

```elixir
{:error, :cleanup_unconfirmed} = RecoveryHost.end_maintenance(host, machine, request_id)
{_, 0} = MachinePool.docker(pool, ["kill", console.container])
{_, 0} = MachinePool.docker(pool, ["wait", console.container])
:ok = RecoveryHost.end_maintenance(host, machine, request_id)

{:ok, replacement} = Workspace.open(profile: :run, infrastructure: machine)

try do
  {:ok, "approved\n"} = Workspace.read(replacement, "review.txt")
  {:ok, snapshot} = Workspace.save(replacement)
  snapshot
after
  :ok = Workspace.close(replacement)
end
```

If a return reply is lost, repeat the end request with the same ID.
That request cannot release the replacement lease. A Workspace open
returns `:infrastructure_busy` until the provider releases the slot.

## API fit and gaps

The host controls access to the external console. Workspace uses the
regular open, file, save, and close calls. Treat each managed SSH or
console session as a writer and verify its exit at the provider. For a
provider that offers persistent SSH access, verify revocation of that
access and use its process controls to account for detached writers.

This fixture uses a local Docker container and a dedicated working tree.
The host service stays up during the handoff. The console has a write
mount of the tree, a read-only root filesystem, and disabled networking.
The host only grants console commands through its control plane. The
Workspace connection has no authority to start maintenance. Tests prove
that a detached process can still write after return begins, that the old
console cannot start again after removal, and that the machine and the
review survive. The replacement snapshot reopens on memory.

## Run the integration test

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/06_providers_and_persistent_infrastructure/06_05_hand_off_to_an_external_maintainer/example_test.exs \
  --include integration
```

The test uses an installed image. Its cleanup targets the labeled local
fixture containers. [Test](example_test.exs)
· [Provider service](../06_03_recover_an_old_command/recovery_host.ex)
