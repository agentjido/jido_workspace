# Owned atomic workspaces

This change coordinates three package boundaries:

| Package | Responsibility | Dependency PR |
| --- | --- | --- |
| Jido VFS | Immutable captures and checked atomic memory edits | [agentjido/jido_vfs#46](https://github.com/agentjido/jido_vfs/pull/46) |
| Jido Shell | Sessions borrow caller-owned filesystems; local commands stop before cleanup | [agentjido/jido_shell#73](https://github.com/agentjido/jido_shell/pull/73) |
| Jido Workspace | Own storage and session lifetime; compose the two APIs | This change |

`mix.exs` and `mix.lock` select the commits from both dependency PRs. No local path
dependencies are required. Review the VFS and Shell contracts first, then this
composition. The dependencies are already Git dependencies so the complete chain
can be tested before the lower-level PRs merge.

Workspace no longer stores a second snapshot history. VFS captures are immutable
values, and state tokens are concurrency preconditions. Neither is a BeamLoom
version identity. BeamLoom retains versions, branches, integration policy,
behavior evidence, transition plans, and evolution records.

## Public seams

- `open/1`: create an environment owned by a process; memory storage is the default.
- `filesystem/1`: return its public VFS handle.
- `shell/1`: start or return its session.
- `capture/1`: capture the root filesystem and state token.
- `replace/3`: replace content only at the supplied token.
- `close/1`: stop the session before releasing storage; repeated close succeeds.

Legacy `new/1` and artifact operations remain. `snapshot/1` returns a capture value
in the former snapshot-ID position. `restore/2` takes that value and uses a fresh
checked replacement. Use `replace/3` when the caller needs to preserve a token
from an earlier read.

## Boundaries and limits

Atomic capture and replacement support a single memory root. Local adapters
explicitly refuse these operations. Extra mounts remain available to legacy file
operations, but are outside capture and the attached root-only shell session.
There is no cross-mount transaction or implicit source export to host files.

The workspace lifetime process monitors its owner and links to owned storage.
Storage failure closes the environment rather than restarting empty. Shell also
monitors the lifetime process, so its session does not survive that owner.
Captures remain usable after all those processes stop.
