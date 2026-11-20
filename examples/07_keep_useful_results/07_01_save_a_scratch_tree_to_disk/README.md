# 07.01 Save a scratch tree to disk

Save a candidate from a memory workspace. Close the workspace and review
the exact saved tree with a read-only profile. Keep the reference if you
approve the candidate. You can reopen it as long as the host keeps the
store and its bundle.

## Save a candidate

The host selects the store directory. The scratch profile has save
permission. The review profile can import from the same store and read
the restored tree.

```elixir
alias Jido.Workspace

root = System.fetch_env!("WORKSPACE_RESULTS_DIR")
Application.put_env(:jido_workspace, :stores, %{"reports" => Path.join(root, "snapshots")})

Application.put_env(:jido_workspace, :profiles, %{
  scratch: %{provider: :memory, policy: [:read, :write, :save], store: "reports"},
  review: %{provider: :memory, policy: :read_only, store: "reports"}
})

{:ok, scratch} = Workspace.open(profile: :scratch)

candidate =
  try do
    :ok = Workspace.write(scratch, "report.txt", "Quarterly report\n")
    {:ok, candidate} = Workspace.save(scratch)
    {:ok, ^candidate} = Workspace.save(scratch)
    candidate
  after
    :ok = Workspace.close(scratch)
  end
```

A repeat save returns the same reference when the tree and store are the
same. Later edits to the live tree leave that saved result intact.

## Review and keep the result

Open the saved candidate to review the exact version that you will keep.
The host can record its JSON reference after approval. The bundle stays in
the store.

```elixir
{:ok, review} = Workspace.open(profile: :review, from: candidate)

approved_reference =
  try do
    {:ok, "Quarterly report\n"} = Workspace.read(review, "report.txt")
    Jason.encode!(candidate)
  after
    :ok = Workspace.close(review)
  end
```

To restore later, decode the reference and use
`Workspace.open(profile: :review, from: Jason.decode!(approved_reference))`.
For the separate BEAM startup workflow, see
[00.04 Restore in a fresh BEAM](../../00_core/00_04_restore_in_a_fresh_beam/README.md).

## API fit and gaps

- The profile identifies the store. A reference from a different store
  is refused even if its bundle exists on the same disk.
- A local file error during publication returns
  `:snapshot_store_unavailable`. Correct the store problem and retry while
  the workspace is open. The failed save returns no reference. An earlier
  valid bundle stays readable.
- Restore checks the file type, size, digest, and tree contents before it
  returns a handle. It refuses a symbolic link in place of a bundle.
- The host retains the bundle and the approved reference. The local
  store uses atomic publication on the same filesystem. The example
  covers workspace close and a failed publication. Power-loss durability
  requires separate verification.

## Run the integration tests

```sh
mix test examples/07_keep_useful_results/07_01_save_a_scratch_tree_to_disk/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/07_keep_useful_results/07_01_save_a_scratch_tree_to_disk/example_test.exs \
  --include integration
```

The tests keep a reviewed snapshot after close, reject a symlink or a
different store, and force publication to fail at the destination.
They verify that the earlier snapshot remains readable and that a retry
saves the new content. The Docker case restores the memory snapshot
through the same API. [Tests](example_test.exs)
