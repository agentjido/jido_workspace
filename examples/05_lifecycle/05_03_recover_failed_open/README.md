# 05.03 Recover a late or failed allocation

Keep the snapshot reference until the next open succeeds. For a profiled
workspace, set `timeout_ms:` to limit the wait for the provider to allocate
and restore the tree. If the wait expires, the call returns `:open_timeout`
with no workspace handle. Workspace releases any resources that arrive late.
[Example](example.ex)

```elixir
alias Jido.Workspace
alias Jido.Workspace.Error

case Workspace.open(profile: :docker, from: snapshot, timeout_ms: 2_000) do
  {:ok, workspace} ->
    {:ready, workspace}

  {:error, %Error{code: :open_timeout} = error} ->
    {:retry_open, snapshot, error}

  {:error, %Error{code: :cleanup_unconfirmed} = error} ->
    {:check_cleanup, snapshot, error}

  {:error, _} = error ->
    error
end
```

Call `Workspace.open/1` again with the saved reference to request a new
disposable tree. The same call works with `profile: :memory`. A new tree
has separate resources from the expired attempt. Keep the saved reference
and its store available across both attempts.

## Run the tests

```sh
mix test examples/05_lifecycle/05_03_recover_failed_open/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/05_lifecycle/05_03_recover_failed_open/example_test.exs --include integration
```

The memory tests hold allocation until the owner or caller exits, or until
the wait expires. They check removal of the mount and reopen the saved
report. The Docker tests check removal of a late sandbox root. They also
hold image inspection after a root exists, block root deletion, and fail the
inspection. Open reports `:cleanup_unconfirmed`. The sandbox retries deletion when the test
restores directory permissions. The permission test requires a non-root
user. [Tests](example_test.exs)

## API fit and gaps

The default allocation wait is 30 seconds. Profile resolution and loading
the saved snapshot occur before this wait. Workspace monitors the caller
until it accepts the handle and monitors the owner for the workspace
lifetime.

The local providers prove rollback in a running BEAM. Release can continue
after an open timeout. The call returns no handle to poll. Recovery of a
persistent machine needs its own lease checks and provider evidence.
