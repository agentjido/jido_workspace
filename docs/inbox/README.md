# Documentation inbox

Review each item against current code, tests, or an accepted decision before
moving it into the main documentation. Keep the original path in this log.

| Date | Source | Destination | Status |
| --- | --- | --- | --- |
| 2026-11-19 | `docs/atomic-workspaces.md` | [Owned atomic workspaces](docs/atomic-workspaces.md) | New. Review current API claims and retain the original history. |
| 2026-11-19 | Owner's infrastructure design review | [Persistent infrastructure and writer ownership](../decisions/2026-11-19-persistent-infrastructure.md) | Placed. Accepted design boundary. |
| 2026-11-19 | `docs/shell/README.md` | [Shell guide](../shell/shell.md) | Published guide. The directory README links to it. |
| 2026-11-19 | `docs/vfs/README.md` | [VFS guide](../vfs/vfs.md) | Published guide. The directory README links to it. |

## Paths kept in place

- Root README, contribution guide, usage rules, change log, and agent
  instructions are entry points or package files. The root API specification,
  Sandbox, and Deploy guides also ship in the package.
- `docs/shell/`, `docs/vfs/`, `docs/source-imports.md`, and
  `docs/workspace-asset-lifecycle.md` are package or ExDoc inputs.
- `docs/plans/` is the existing plan directory. Both plan paths remain stable.
- `bench/search/` contains reports kept with the benchmark material.
