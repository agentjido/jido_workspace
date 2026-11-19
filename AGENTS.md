# Jido.Workspace

`jido_workspace` contains the Workspace API, Shell sessions, and VFS adapters.
Keep their module boundaries within the single OTP application.

- `Jido.Workspace` manages workspaces, access policy, mounted files, and Shell sessions.
- `Jido.VFS` provides storage adapters and atomic InMemory captures.
- `Jido.Shell` runs commands over mounted filesystems.
- `Jido.Workspace.Sandbox` manages execution environments and services.
- `Jido.Workspace.Deploy` manages deployment plans and transitions.

Use `Jido.Workspace.open/1` and `close/1` to manage a live workspace. Use
`capture/1` and revision-checked `replace/3` to work with captured content.
See the [README](README.md) for the full file and execution APIs.

## Checks

- `mix test` runs the default suites.
- `mix test.integration` runs the isolated Workspace examples.
- `mix quality` runs format, compile, lint, type, and documentation checks.
- `mix test.coverage` combines coverage from the default suites, Workspace
  examples, and local VFS adapter integration tests.
- `mix hex.build` builds the local package artifact.

## Scope

Keep provider orchestration, harness runtime policy, and Sprite workflows in
the host application. Keep Jido integration in test scope.

See [imported source revisions](docs/source-imports.md) for provenance.
Do not edit `CHANGELOG.md`. The release workflow generates it from Git history.
