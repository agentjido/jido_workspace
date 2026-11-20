# 03.02 Keep paths within the root

Use paths relative to the workspace root for file calls and `cwd:`. The
same calls work on memory and Docker when the host supplies the named
profiles from the [examples guide](../../README.md#save-and-reopen-after-a-beam-restart).

```elixir
alias Jido.Workspace

{:ok, workspace} = Workspace.open(profile: :memory)
:ok = Workspace.write(workspace, "reports/-report.txt", "Workspace report\n")
{:ok, "Workspace report\n"} = Workspace.read(workspace, "reports/-report.txt")

{:ok, %{exit_status: 0, output: "Workspace report\n"}} =
  Workspace.run(workspace, ["cat", "./-report.txt"], cwd: "reports")

{:error, %Workspace.Error{code: :invalid_input}} =
  Workspace.write(workspace, "../report.txt", "Rejected")

:ok = Workspace.close(workspace)
```

The `./` prefix in the command argument identifies the file even though its
name starts with a hyphen. The selected tool interprets each argument.
[RootedReport](example.ex) uses the same sequence on either provider.

| Request | Result |
| --- | --- |
| Absolute path, parent segment, or repeated separator in a file call or `cwd:` | `:invalid_input` |
| A symbolic link at any component of a file path or `cwd:` on Docker | `:symlink_path` |
| A symbolic link in a directory that the file API lists or saves | `:unsupported_capability` |
| Search from a valid directory | Search visits regular files and directories. It skips links. |
| Replace an existing file with other hard-link names | The named entry gets new bytes. The other names keep their bytes. |

## Docker fixture

The test creates a host file outside a temporary checkout. It supplies a
file link and a directory link inside the checkout. Workspace refuses file
calls through the links. A native command that reads through either link
exits with a nonzero status inside the container. An approved command removes
the links, then Workspace can save the remaining tree and reopen it in memory.

A hard link supplied by the host is a regular entry in the checkout.
Its existing bytes are readable. File writes replace the selected entry and
preserve its read, write, and execute permission bits. File deletes remove
only the selected name. The host
chooses which files to share through the checkout and coordinates external
edits while Workspace holds it. Native commands use container filesystem
semantics, including the image's own files and the shared checkout.

```sh
mix test examples/03_security_and_policy/03_02_keep_paths_within_the_root/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/03_security_and_policy/03_02_keep_paths_within_the_root/example_test.exs \
  --include integration
```

The Docker tests need a local engine with the image installed.
[Integration tests](example_test.exs)
