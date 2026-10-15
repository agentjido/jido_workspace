# Jido.Workspace

[![Hex.pm](https://img.shields.io/hexpm/v/jido_workspace.svg)](https://hex.pm/packages/jido_workspace)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_workspace/)
[![CI](https://github.com/agentjido/jido_workspace/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_workspace/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_workspace.svg)](https://github.com/agentjido/jido_workspace/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

Unified artifact workspace for agent sessions, built on `jido_shell` + `jido_vfs`.

## Package Boundary

`jido_workspace` is a strict workspace library. It owns:

- Workspace state and artifact lifecycle
- Optional shell-session convenience bound to workspace id
- Snapshot/restore of workspace artifacts

It does **not** own:

- Provider orchestration
- Harness runtime policy/bootstrap
- Sprite workflow orchestration

## Installation

Add `jido_workspace` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_workspace, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Create a new workspace (in-memory VFS mounted at /)
workspace = Jido.Workspace.new()

# Work with artifacts
{:ok, workspace} = Jido.Workspace.write(workspace, "/hello.txt", "Hello, World!")
{:ok, "Hello, World!"} = Jido.Workspace.read(workspace, "/hello.txt")
{:ok, ["hello.txt"]} = Jido.Workspace.list(workspace, "/")

# Snapshot and restore
{:ok, capture, workspace} = Jido.Workspace.snapshot(workspace)
{:ok, workspace} = Jido.Workspace.delete(workspace, "/hello.txt")
{:ok, workspace} = Jido.Workspace.restore(workspace, capture)

# Run a shell command in the workspace
{:ok, output, workspace} = Jido.Workspace.run(workspace, "pwd")

# Cleanup
{:ok, workspace} = Jido.Workspace.close(workspace)
```

## Why Jido.Workspace

- Unifies artifact lifecycle for an agent session
- Uses `Jido.Shell.VFS` for mount/routing
- Uses `Jido.VFS` adapter ecosystem for storage backends
- Provides a single state struct for files + session context

## Workspace vs Harness Exec

- Use `Jido.Workspace` when you need app-level stateful workspace operations:
: artifact files, snapshots, and optional shell command execution tied to that workspace.
- Use `Jido.Harness.Exec.Workspace` when you need provider-runtime orchestration primitives:
: provisioning/validation/bootstrap around coding-agent execution.

## Documentation

See [HexDocs](https://hexdocs.pm/jido_workspace) for full documentation.

## License

Apache-2.0

## Testing Paths

- Core workspace suite: `mix test`
- Full quality gate: `mix quality`
- Keep scenario-heavy testing in `jido_workspace_scenarios`

## Owned workspace lifecycle

```elixir
{:ok, workspace} = Jido.Workspace.open(owner: self())
{:ok, filesystem} = Jido.Workspace.filesystem(workspace)
{:ok, session} = Jido.Workspace.shell(workspace)
{:ok, saved, token} = Jido.Workspace.capture(workspace)
{:ok, next_token} = Jido.VFS.apply_edits(filesystem, token, [{:write, "file", "new"}])
{:ok, _} = Jido.Workspace.replace(workspace, next_token, saved)
{:ok, _} = Jido.Workspace.close(workspace)
```

Workspace owns storage and its optional shell session. Shell borrows that storage.
Repeated `shell/1` calls return the same active session. Owner exit closes the
session and storage. A storage process failure closes the environment; it does
not restart an empty filesystem. Close is idempotent and stops active local
commands before storage is released. Captures remain readable after close.

### Snapshot API change

`snapshot/1` retains its three-element result tuple, but now returns an immutable
`Jido.VFS.Capture` instead of a `snap-N` string. Pass that value to `restore/2`.
There is no workspace snapshot map or counter. `restore/2` captures a current
precondition and performs checked replacement; use `replace/3` to supply the
expected token from an earlier read explicitly.

Only the memory backend currently provides atomic capture and replacement.
Local storage now returns `UnsupportedOperation` instead of copying a tree that
can change during capture. Capture and replacement refuse multiple mounts.
The attached shell session sees the owned root filesystem; additional mounts
remain available through the legacy workspace file API, not that shell session.

BeamLoom version IDs, branches, merge policy, acceptance receipts, and deployment
remain outside this package. Storage captures carry no branch history.
