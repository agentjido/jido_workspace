# 01.01 Edit and list a project

Use the same file calls on memory and Docker. Start with a named profile
and use paths relative to the workspace root.

```elixir
alias Jido.Workspace

{:ok, workspace} = Workspace.open(profile: :memory)
:ok = Workspace.mkdir(workspace, "project/inbox")
:ok = Workspace.mkdir(workspace, "project/review")
:ok = Workspace.write(workspace, "project/inbox/draft.txt", "Draft for review\n")
:ok = Workspace.move(workspace, "project/inbox/draft.txt", "project/review/draft.txt")
:ok = Workspace.delete(workspace, "project/inbox")

{:ok, "Draft for review\n"} = Workspace.read(workspace, "project/review/draft.txt")
{:ok, [%Workspace.Entry{path: "project/review/draft.txt", kind: :file}]} =
  Workspace.list(workspace, "project/review")

{:ok, snapshot} = Workspace.save(workspace)
:ok = Workspace.close(workspace)
```

[EditProject](example.ex) runs the same edits and returns the draft and
the entries. Listing returns the direct children in path order. Paths
in those entries are relative to the workspace root, including when you
list a subdirectory. The provider supplies the metadata it knows.

## File results

| Request | Result |
| --- | --- |
| List an empty directory | `{:ok, []}` |
| Read, list, move from, or delete a missing path | `:not_found` |
| List a file as a directory | `:not_directory` |
| Delete a directory that contains entries | `:directory_not_empty` |
| Move to an occupied path | `:already_exists`. Both entries stay in place. |

`mkdir/2` creates missing parent directories and preserves entries when
the directory already exists. `move/3` accepts a file or directory.
Create the destination parent first. A successful directory move
carries all its entries, including empty directories.

## Run the tests

```sh
mix test examples/01_working_files/01_01_edit_and_list_a_project/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/01_working_files/01_01_edit_and_list_a_project/example_test.exs --include integration
```

The memory and Docker tests run the same project workflow. A command
reads the moved draft, and a read-only workspace restores it from a
snapshot. The Docker test also checks that a move refuses symbolic
links and uses the supplied name for a hard link. [Tests](example_test.exs)

## API fit and gaps

The controller serializes file operations and checks write permission
before a move. On Docker, Workspace checks the destination and uses a
native rename within the owned tree. This guarantee depends on control
of the tree's writers. A process that edits the directory directly on
the host bypasses the controller.
