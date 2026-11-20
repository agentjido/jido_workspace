# 01.04 Find and inspect files

Search a project for a text marker, then read a match for review. The
same calls work on memory and Docker.

```elixir
alias Jido.Workspace

{:ok, workspace} = Workspace.open(profile: :review, from: snapshot)

try do
  {:ok, matches} = Workspace.find(workspace, "src", contains: "release [draft]")

  for entry <- matches do
    {:ok, bytes, revision} = Workspace.read(workspace, entry.path, revision: true)
    %{path: entry.path, bytes: bytes, revision: revision}
  end
after
  :ok = Workspace.close(workspace)
end
```

The host configures the discovery settings for each named profile.
For example, give a read-only review profile these settings when it
restores a saved project.

```elixir
%{
  provider: :memory,
  policy: :read_only,
  store: "results",
  discovery: %{hidden: false, binary: false, exclude: ["build"]}
}
```

Use `Workspace.find(workspace)` to list regular files in the whole tree.
With `contains:`, the search matches literal bytes and returns the
matching entries in path order. Use the entry path with `read/3` to
inspect the file and get a revision for a later edit.
[Example source](example.ex)

## Discovery settings

| Setting | Default | Effect |
| --- | --- | --- |
| `hidden` | `false` | When false, skip paths that have a component that starts with a dot. |
| `exclude` | `[]` | Skip these exact root-relative paths and their descendants. Use this for generated directories such as `build`. |
| `binary` | `false` | When false, content searches match only valid UTF-8 files that have no NUL bytes. Lists without `contains:` include paths of binary files. |
| `max_entries` | 10,000 | Bound the total number of directory entries the search can inspect. All names in each opened directory count toward the limit. |
| `max_bytes` | 8 MiB | Bound the total bytes examined by a content search. |

These settings select search results. The workspace read policy controls
direct file access. A search returns `:discovery_limit` when it reaches a
limit before it can finish. Narrow the search to a directory before retrying.
Docker reads the names of one directory at a time before it checks the
entry limit for that directory. It skips symbolic links and special files.
The host coordinates any processes that edit a checkout outside Workspace.

The workspace returns `:busy` for other file operations while a search
is active. A later read uses the file at the time of that read. Use its
revision if you plan to write an edit.

## Run the tests

```sh
mix test examples/01_working_files/01_04_find_and_inspect_files/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 \
  mix test examples/01_working_files/01_04_find_and_inspect_files/example_test.exs --include integration --warnings-as-errors
```

The tests restore a fixture with hidden files, generated output, and two
types of binary content. They compare results and scan limits on memory
and Docker. The Docker test also checks symbolic links and a named pipe.
The memory test holds a search open while it checks that another caller
cannot change the tree. [Tests](example_test.exs)
