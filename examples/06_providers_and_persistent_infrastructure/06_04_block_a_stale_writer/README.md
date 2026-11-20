# 06.04 Block a stale writer

When replacing a writer, the host first revokes the old lease at the
provider. This blocks new work under that lease. The provider keeps
the writer slot occupied until it also verifies that commands the old
lease started can no longer write. Only then can a new workspace open
on the same machine.

## Recover a writer slot

The example uses the same provider and profiles as
[06.03 Recover an old command](../06_03_recover_an_old_command/README.md).
All profiles for this tree use the same provider service. The service
owns the lease and command records. Use its operator
functions to find and revoke the exact lease. Choose whether to wait
for each old command or stop it. In this example the host chooses to stop.

```elixir
alias Jido.Workspace
alias Jido.Workspace.Examples.RecoveryHost

{:ok, old_id} = RecoveryHost.current_writer(host, machine)
{:error, :cleanup_unconfirmed} = RecoveryHost.revoke_writer(host, machine, old_id)
{:ok, %{status: :running}} = Workspace.recover_command(:recovery, command, :inspect)

{:ok, %{status: :exited}} = Workspace.recover_command(:recovery, command, :stop)
:ok = RecoveryHost.revoke_writer(host, machine, old_id)

{:ok, workspace} = Workspace.open(profile: :run, infrastructure: machine)

try do
  :ok = Workspace.write(workspace, "review.txt", "Ready\n")
  {:ok, snapshot} = Workspace.save(workspace)
  snapshot
after
  :ok = Workspace.close(workspace)
end
```

The first revoke bars the old lease and reports `:cleanup_unconfirmed`
while a previous writer can still act. The repeat checks all of that
lease's commands and releases only that lease. A lost or repeated
release for the old lease cannot release the replacement.

If the provider connection fails, recovery reports `:quiescence_unknown`.
An open can report `:cleanup_unconfirmed` if Workspace also cannot verify
release of its attempted lease. Restore the connection and inspect the
same command reference. A live provider that still holds the old lease
refuses a second open with `:infrastructure_busy`.

## API fit and gaps

- `Workspace.open/1` gets the writer lease through the configured provider.
  The provider checks the lease when it admits file edits, commands, or
  captures. These checks run in the same service that revokes leases.
- If an old BEAM uses a revoked handle, the provider returns
  `:lease_revoked`. Workspace records that phase and refuses more work on
  the handle. `info/1` and `close/1` still work for diagnosis and release.
- The provider's host API decides when to revoke a lease after a node or
  connection fails. The common Workspace API handles the work and the
  recovery reference. A snapshot records the captured tree separately.

The fixture uses a dedicated machine container and one isolated job
container per command on a local Docker engine. The writer can finish a
file after revocation but before the provider releases the old lease.
The tests keep one old BEAM alive and send stale requests after the
replacement opens. A separate test closes and reopens the local provider
listener with the old job still active. The replacement can save the tree
and restore it on memory. The provider service keeps its records during
these tests and owns cleanup of its labeled test containers.

## Run the integration tests

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/06_providers_and_persistent_infrastructure/06_04_block_a_stale_writer/example_test.exs \
  --include integration
```

The controller test also runs without Docker. [Tests](example_test.exs)
· [Host service](../06_03_recover_an_old_command/recovery_host.ex)
· [Provider](../06_03_recover_an_old_command/recovery_provider.ex)
