# 00.04 Restore in a fresh BEAM

Open a memory workspace, write a report, and save the tree with
`Workspace.save/1`. Write the returned snapshot reference to a JSON file.
After the first BEAM exits, a second BEAM reads the reference and calls
`Workspace.open(profile: ..., from: snapshot)`. It uses the same store ID
and directory. The JSON file identifies the snapshot. The store holds the
file data. [Example](example.ex) · [Restart tests](example_test.exs)

The tests verify binary file contents, an empty directory, and that damage
to a later saved tree leaves an earlier snapshot usable. The Docker case
reopens a tree saved on memory with the same Workspace API.

```sh
mix test examples/00_core/00_04_restore_in_a_fresh_beam/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/00_core/00_04_restore_in_a_fresh_beam/example_test.exs --include integration
```

Use two IEx sessions to reproduce the save and restore.
[Save and reopen a snapshot](../../README.md#save-and-reopen-after-a-beam-restart)
