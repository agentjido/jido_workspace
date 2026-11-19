# Workspace asset lifecycle proposal

Status is proposed for owner review. The combined package supplies the live
workspace, capture, execution, and deployment primitives that this design uses.

## Ownership and identity

A workspace handle owns a live file view and execution sessions. Its owner
controls access. The handle becomes unusable when it closes or the owner
exits. A saved asset belongs to a store configured by the host. Its reference
stays usable after the live resources close and after a BEAM restart on the
same host, provided the store and its files remain available.

Keep three identities with distinct uses:

| Value | Use |
| --- | --- |
| Live Workspace handle | Access mounted files, apply policy, and manage execution. |
| Live revision token | Check that a mutation or command starts with the expected content. A reopened workspace has a new token. |
| Saved asset reference | Locate and verify an immutable saved file tree. It carries a format version, store identifier, and content digest. The host resolves and authorizes access to the store. |

Persist file bytes, canonical relative paths, empty directories, and supported
modes. Serialize portable metadata only. PIDs, runtime revision tokens,
credentials, mounts, and policy remain outside the asset. Source history and
branches belong to the source manager.

## Public workflow

These names and signatures are design candidates.

```elixir
{:ok, workspace} = Jido.Workspace.open(policy: :workspace_write)
:ok = Jido.Workspace.write(workspace, "/report.md", "Draft")
{:ok, asset} = Jido.Workspace.save(workspace, store: :work_assets)
:ok = Jido.Workspace.close(workspace)

# A fresh process or node can use the same saved asset.
{:ok, reopened} = Jido.Workspace.reopen(asset, policy: :read_only)
{:ok, "Draft"} = Jido.Workspace.read(reopened, "/report.md")
:ok = Jido.Workspace.close(reopened)
```

- **Open and work.** Continue to use the existing file operations and virtual
  Shell. Keep command and Sandbox capabilities explicit. Workspace execution
  observes its live file view. Sandbox execution uses an explicitly projected
  tree and records the asset reference and its separate execution result.
- **Save.** Capture one atomic InMemory root through the existing VFS contract.
  Check export permission and any expected live revision at the capture point.
  A save represents the files at that point. Later writes remain possible and
  have no effect on the saved asset. Return an unsupported capability error for
  multiple mounts or an adapter that cannot provide a consistent capture.
- **Close.** Release the live workspace and sessions. In the explicit-save
  design, edits made after the last successful save are lost when the memory
  workspace closes. The saved asset stays available.
- **Reopen.** Load and verify the saved content, authorize the caller, then
  restore into a fresh root. Publish the handle only after restore succeeds
  and the requested policy is in force. Release partially acquired resources
  on errors. A read-only reopened workspace is read-only from the first call
  the caller can make.
- **Hand off.** Project an exact saved asset into a Sandbox or explicitly
  convert it to a Deploy snapshot. Preserve asset metadata in the store.
  Let each export target report unsupported entries or metadata according to
  its contract. Retention and removal belong to the host.

## First store candidate

Use a host-configured local directory and a versioned bundle per immutable
asset. Encode entries in a canonical order and hash the encoded content.
Validate sizes, entry types, duplicate paths, and path relationships on read.
A bundle uses regular files and directories with the modes supported by the
current capture contract. Symlinks and special files require separate
representation and validation decisions. A store can enforce a size limit
before admitting a save or allocating a restored tree.

Write a complete bundle to a temporary file in the same directory. Validate it
and publish it with a filesystem operation that gives readers atomic
visibility. Return success only when the store can reopen the published bundle.
Require file and directory sync for any guarantee that includes sudden power
loss, and test those guarantees on the supported filesystems. Start with an
explicit BEAM restart guarantee on the same host. Host loss and recovery from
backup require a different storage contract.

Content-addressed references allow retries with the exact same capture. The
design can offer a save operation for an authorized caller that still holds
that immutable value. Calling save on a live workspace again takes a new
capture and can return a different reference. If the caller loses the reply
and the exact capture in a node crash, recovery of that reference would need a
durable operation receipt. Decide whether the first consumer needs receipts.
If two writers save different trees, both immutable references can exist.
If the API later adds a mutable named
reference, advance it with an expected saved revision. A stale update must leave
its previous value available. Delay named references until a consumer needs them.

## Failure behavior to verify

| Event | Expected outcome |
| --- | --- |
| Workspace owner exits before any save | The sessions and mounted memory tree close. There is no saved asset for those edits. |
| Node stops during save before publication | A prior asset stays readable. A temporary write cannot appear as a valid saved reference. The store can clean unused temporary writes on restart. |
| Node stops after save success | A fresh node can reopen the reference. Changes after the capture are absent. |
| Save publishes and the caller loses the reply | A caller that holds the exact capture can retry for the same reference. Recovery without that capture requires a durable receipt. |
| Save races a command or checked edit | The capture describes one valid file state. A stale expected live token fails before publication. |
| Load fails midway or the digest is wrong | Return an error. Expose no live handle and retain the saved asset for inspection. |
| Host requests deletion | Require a distinct store policy and authorization. Keep automatic deletion outside the first save and reopen contract until ownership and retention rules are specified. |

## Decisions for review

- Confirm explicit save as the first persistence model and decide whether the
  first consumer also requires automatic recovery of unsaved edits.
- Choose the initial store, failure guarantee, and retention rules. Confirm
  whether local BEAM restart recovery meets the first use case.
- Choose whether asset references need labels or mutable heads in the first
  version. Decide who can export or remove saved assets.
- Confirm the facade operations and the role of the existing lower-level
  APIs. Define a single error contract for stale revisions, unsupported
  storage, missing assets, and invalid content.

The first implementation should prove save, close, new BEAM start, reopen,
and content equality before widening the backend or API. A later agent
integration can attach a live workspace to an activation and keep only the
asset reference in durable agent state.
