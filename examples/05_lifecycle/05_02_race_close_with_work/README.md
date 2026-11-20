# 05.02 Close while work is running

Use `Workspace.close/2` to bound how long the caller waits. Once the
controller accepts close, it refuses new writes, commands, and saves. An
accepted command or save can finish before the provider releases the tree.
Keep the last snapshot reference for recovery. [Example](example.ex)

```elixir
alias Jido.Workspace
alias Jido.Workspace.Error

case Workspace.close(workspace, timeout_ms: 100) do
  :ok ->
    {:closed, last_saved_snapshot}

  {:error, %Error{code: :cleanup_unconfirmed}} ->
    {:cleanup_unconfirmed, workspace, last_saved_snapshot}

  {:error, _} = error ->
    error
end
```

The default wait for a profiled workspace is 30 seconds. If the wait expires,
close can continue in the background. Call close again with the same handle
to wait for confirmation. A retry also works after confirmed release. If the
controller disappears before recording confirmation, the handle expires and
close reports `:cleanup_unconfirmed`.

## Run the tests

```sh
mix test examples/05_lifecycle/05_02_race_close_with_work/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/05_lifecycle/05_02_race_close_with_work/example_test.exs --include integration
```

The memory tests hold a save, a command, and a release at known points. They
check that new work returns `:closed`, a retry can observe release, and an
earlier snapshot is usable after a failed save. The Docker test keeps a
native command running until close is accepted, then checks that the command
returns and that the container and workspace directory are removed.
[Tests](example_test.exs)

## API fit and gaps

The same close call works on memory and Docker. The wait limit applies to the
caller. The admitted work keeps its own execution or storage limits. A
confirmed release applies to this handle in the running BEAM. Recovery of
resources after BEAM or host loss needs evidence from the provider.
