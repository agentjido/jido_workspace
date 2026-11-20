# Workspace guides

Use this index to find the Workspace workflow, supporting APIs, and runnable
examples. Reviewed on 2026-11-19.

## Start here

- [Install from a local checkout](../../README.md#use-from-another-project)
- [Open one working tree](../../README.md#open-one-working-tree) to edit files,
  run a command, save the result, and reopen it for review.
- [Run the numbered examples](https://github.com/agentjido/jido_workspace/tree/main/examples)
  for workflows that exercise the public API.

## Work with files and commands

- `Jido.Workspace` covers relative paths, revision-checked edits, file search,
  and large file reads and writes.
- Use `Jido.Workspace.run/3` for literal arguments and a working directory.
  Use `Jido.Workspace.batch/2` for ordered edits and commands.
- Use `Jido.Workspace.info/1` and `Jido.Workspace.output/3` to inspect a live
  command. Use `Jido.Workspace.cancel/2` to request a stop.

## Choose an execution environment

- `Jido.Workspace.Profile` defines the provider, tools, limits, and required
  capabilities. `Jido.Workspace.Policy` defines the operations it grants.
- [Sandbox guide](../../SANDBOX.md) covers local processes, containers,
  service lifetimes, and cleanup. Check the provider's capabilities before
  you depend on an isolation or cancellation guarantee.
- `Jido.Workspace.Provider` defines the callbacks for hosts that supply their
  own file tree and runner or attach to persistent infrastructure.

## Save, recover, and deploy

- Use `Jido.Workspace.save/1` for a portable tree. Keep its
  `Jido.Workspace.Snapshot` reference to [reopen it for review](../../README.md#open-one-working-tree).
- Use `Jido.Workspace.InfrastructureRef` to identify a persistent resource.
  Use `Jido.Workspace.CommandRef` and `Jido.Workspace.recover_command/4` to
  inspect, wait for, or stop a job after client loss. The host confirms old
  writers have stopped before it grants replacement write access.
- [Deploy guide](../../DEPLOY.md) covers [saved trees](../../DEPLOY.md#saved-workspace-trees),
  [recovery](../../DEPLOY.md#failure-and-recovery), and
  [OTP release upgrades](../../DEPLOY.md#otp-release-upgrade).

## Use Shell and VFS directly

- [Shell sessions](../shell/shell.md) covers Shell commands, mounts, and backends.
- [Virtual filesystems](../vfs/vfs.md) covers storage adapters, streaming,
  versioning, and atomic memory captures.
- [VFS in Jido agents](../vfs/jido-agent-integration.md) describes how a host
  application can expose selected operations as Actions.

## Maintain the package

- [VFS adapter checklist](../vfs/adapter-onboarding-checklist.md)
- [Shell guardrails](../shell/GUARDRAILS.md) and [migration](../shell/MIGRATION.md)
- [Contributing](../../CONTRIBUTING.md), [change log](../../CHANGELOG.md), and
  [source imports](../source-imports.md)
- [License](../../LICENSE)

## Earlier designs

- [Workspace API proposal](../../API_SPEC.md)
- [Workspace asset lifecycle proposal](../workspace-asset-lifecycle.md)
