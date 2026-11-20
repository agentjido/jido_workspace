# 01.03 Apply an edit against a known revision

Two editors can read the same draft and prepare different changes. Use the
revision from the read to prevent a late edit from overwriting the first one.

```elixir
alias Jido.Workspace

{:ok, workspace} = Workspace.open(profile: :memory)

try do
  :ok = Workspace.write(workspace, "draft.txt", "Original\n")
  {:ok, original, revision} = Workspace.read(workspace, "draft.txt", revision: true)

  :ok =
    Workspace.write(workspace, "draft.txt", [original, "First edit\n"],
      expected: revision
    )

  {:error, %Workspace.Error{code: :stale_revision}} =
    Workspace.write(workspace, "draft.txt", [original, "Second edit\n"],
      expected: revision
    )

  {:ok, "Original\nFirst edit\n"} = Workspace.read(workspace, "draft.txt")
after
  :ok = Workspace.close(workspace)
end
```

Use the same calls with a Docker profile. When a write returns
`:stale_revision`, read the latest bytes and prepare the edit again.
[Example source](example.ex)

## Revision rules

- `read/3` returns the bytes and their revision from one read. Ordinary
  `read/2` still returns only the bytes.
- `write/4` uses the same `expected:` option as the tree replacement API.
  A changed or deleted file returns `:stale_revision` and the write has
  no effect. The profile checks write permission before the comparison.
- A revision describes the bytes. The same bytes give the same revision,
  even after another edit restores them. File mode and edit history
  are outside the comparison.
- Memory checks and changes the file in one storage update. Docker checks
  and replaces the named file in the same controller call. The native
  replacement uses a rename and preserves the ordinary permission bits.
  Coordinate processes that write directly to a host checkout with the
  workspace owner.

## Run the tests

```sh
mix test examples/01_working_files/01_03_apply_an_edit_against_a_known_revision/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 \
  mix test examples/01_working_files/01_03_apply_an_edit_against_a_known_revision/example_test.exs --include integration --warnings-as-errors
```

Both providers use a message barrier so both callers read before either
can write. The tests check that the winner's edit stays, a fresh edit can
proceed, a command can change the revision, and a read-only profile refuses
the write. The Docker test also checks hard links, symbolic links, and a
named pipe in the disposable tree. [Tests](example_test.exs)
