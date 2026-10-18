# Jido.Workspace Usage Rules

## For LLM Tool Builders

## Scope Boundary

- `jido_workspace` owns workspace state + artifact/session convenience only.
- Do not add provider orchestration, harness runtime policy, or sprite workflow orchestration here.
- Keep this package reusable as a shell+VFS workspace library.

### Allowed Operations

- Read/write files in workspace artifacts
- List directory contents
- Create/delete directories and files
- Capture and restore workspace snapshots
- Run shell commands in a workspace session

### Path Rules

- Paths MUST be absolute (start with `/`)
- Path traversal (`..`) is blocked
- Paths are case-sensitive
- Multiple slashes are normalized

### Session Rules

- `run/3` auto-starts a workspace session if needed
- Sessions are tied to a single workspace id
- Use `close/1` to stop session and unmount filesystems

### Backend Rules

- Root mount defaults to in-memory adapter
- Custom `Jido.VFS` adapters are supported via `new/1` options
- Workspace file operations route through `Jido.Shell.VFS`
