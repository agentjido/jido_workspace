# Jido Workspace

A local package for agent working files, execution environments, deployment,
and policy. VFS and Shell remain separate packages. Source history remains in
BeamWeaver.

See [the API proposal](API_SPEC.md) for contracts, Action and Signal boundaries,
and the migration plan. This package is unreleased. API changes apply directly
in `Jido.Workspace`; there is no separate compatibility facade.

## File API

```elixir
alias Jido.Workspace

{:ok, ws} = Workspace.open(policy: :workspace_write)
:ok = Workspace.mkdir(ws, "/src")
:ok = Workspace.write(ws, "/src/input.txt", "hello")
{:ok, "hello"} = Workspace.read(ws, "/src/input.txt")
:ok = Workspace.delete(ws, "/src/input.txt")
:ok = Workspace.close(ws)
:ok = Workspace.close(ws)
```

Keep the same handle after file changes. The controller owns mutable state and
checks policy. All Workspace methods return structured errors
with a code, operation, resource ID, and bounded cause. Paths must be absolute
UTF-8 paths without NUL or parent traversal. Writes accept iodata. The caller
owns the Workspace unless the host sets `owner:`. Open resources before passing
them to short-lived Action tasks.

`list` returns Entry records with absolute paths. `info` returns current policy,
owner, and session status. `capture` returns immutable content and a revision.
Use `replace(ws, capture, expected: revision)` for checked replacement.
`run` returns an Execution record. Keep the same handle; it has no cached
session or command fields. `new`, `snapshot`, `restore`, and `execute` are removed.

`test/examples/workspace_file_api_test.exs` and `workspace_contract_test.exs`
run file, capture, command, session, and policy checks directly, through
`Jido.Exec`, and through a real AgentServer with
Jido Signals. Its Actions and Signal adapter remain test-only. No model is used.

## Internal boundaries

| Module | Responsibility |
| --- | --- |
| `Jido.Workspace` | Working-file and Shell API |
| Jido.Workspace.Lifetime (internal) | Ownership of mounted storage and Shell sessions |
| `Jido.Workspace.Sandbox` | Local processes, Docker/gVisor containers, files, and retained services |
| `Jido.Workspace.Deploy` | Targets, preparation plans, execution records, and recovery |
| `Jido.Workspace.Deploy.OTP` | OTP release handling and explicit state migration |
| `Jido.Workspace.Deploy.Source` | Source projection, activation, and service restart |
| `Jido.Workspace.Policy` | Permission checks used by Workspace controllers |
| `Jido.VFS` dependency | Storage adapters and atomic file captures |
| `Jido.Shell` dependency | Shell sessions and command execution |

All Elixir source is under `lib/jido_workspace/`, except the public facade at
`lib/jido_workspace.ex`. The target-side OTP control module is in `src/`.
Sandbox and Deploy retain separate registries, supervisors, and tests.
They share one OTP application, `:jido_workspace`.

An in-memory workspace and an OS environment are explicit, separate resources.
Opening one does not open the other. Deploy takes an Sandbox handle.
A deployment `Snapshot` is a file payload with a digest and a caller-supplied
source ID. It does not own branches, commits, merges, or source history.

## Target and file boundaries

Deploy resolves every target through Sandbox before it connects. Target identity
uses the controller-owned Sandbox ID and a canonical relative path. Dot paths,
trailing separators, and case aliases on a case-insensitive filesystem cannot
create a second deployment controller. Symlink traversal is refused. Concurrent
connections use the same registry key. This is one-controller protection within
one Workspace application. It is not a distributed deployment lock.

Deploy sends target reads, writes, directory creation, file checks, link
activation, and OTP release-file setup through Sandbox. The local provider owns
those OS calls. `Snapshot.from_directory/2` and `Snapshot.verify/2` remain explicit
host-side import and check helpers. They are not used to inspect deployed files.
No remote provider is added by this change.

## Command file views

A `Jido.Workspace.FileView` names the file source, owner, path, and observed
revision. Workspace views describe mounted VFS files. Sandbox views describe a
directory in that environment. The two kinds cannot be substituted.

```elixir
{:ok, workspace} = Jido.Workspace.open()
:ok = Jido.Workspace.write(workspace, "/input", "draft")
{:ok, view} = Jido.Workspace.file_view(workspace)
{:ok, record} = Jido.Workspace.run(workspace, "cat /input", files: view)
"draft" = record.output
^view = record.files
:ok = Jido.Workspace.close(workspace)

{:ok, sandbox} = Jido.Workspace.Sandbox.open()
:ok = Jido.Workspace.Sandbox.write(sandbox, "input", "draft")
{:ok, view} = Jido.Workspace.Sandbox.file_view(sandbox)
{:ok, result} = Jido.Workspace.Sandbox.exec(sandbox, "/bin/cat", ["input"], files: view)
^view = result.files
:ok = Jido.Workspace.Sandbox.destroy(sandbox)
```

The `:files` option accepts a view or `:current` (the default).
A stale view is refused before the command or service starts. Sandbox services
record the input view in their status. Deploy command evidence includes these
records. Sandbox revisions hash file contents and executable modes; directory
names and symlink destinations are also included. Links are recorded without
following them. This is a full directory scan for each command start.

`Workspace.run/3` returns `{:ok, %Execution{}}`, including `files` and
`after_files`, combined `output`, `exit_status`, `status`, `truncated`, and
`duration_ms`. Nonzero exits remain successful observations. Timeouts return
status `:timed_out` and cancel the command. Options use `timeout_ms:` and
`output_limit:`. A final file observation error stays in `after_files`.

VFS adapters that do not supply a capture revision, and workspaces with multiple
mounts, report `revision: :unavailable`. A named view with that revision is
refused with `:unversioned_file_view`. Commands can still use `files: :current`.

These revisions are pre-start observations and checks. They do not lock files or
make a command's file view immutable. Another process or a raw file handle can
change files during execution. There is no automatic synchronization between
memory files and Sandbox files. Use a projected, isolated tree when execution
must use fixed content.

## Policy

Set `policy:` when you open a workspace or an environment. The controller keeps
this value for its lifetime. Handles and command options cannot change it.

| Profile | Read and capture | File changes | Raw VFS or Shell handle | OS execution and deployment |
| --- | --- | --- | --- | --- |
| `:read_only` | Allow | Deny | Deny | Deny |
| `:workspace_write` | Allow | Allow | Deny | Deny |
| `:full_access` | Allow | Allow | Allow | Allow |

The default is `:full_access`. This keeps the current local access rules.
A host that exposes tools to an agent must select the
required profile explicitly.

```elixir
{:ok, workspace} = Jido.Workspace.open(policy: :workspace_write)
:ok = Jido.Workspace.write(workspace, "/notes.txt", "draft")
{:error, %Jido.Workspace.Error{code: :policy_denied}} = Jido.Workspace.run(workspace, "pwd")
:ok = Jido.Workspace.close(workspace)

{:ok, environment} = Jido.Workspace.Sandbox.open(policy: :full_access)
{:ok, result} = Jido.Workspace.Sandbox.exec(environment, "/bin/echo", ["ready"])
"ready\n" = result.output
:ok = Jido.Workspace.Sandbox.destroy(environment)
```

Restricted profiles refuse all Shell execution. This prevents a command from
bypassing file permissions. There is no command approval queue or policy editor
in this spike. Resource close and environment destroy remain available for
cleanup under every profile.

These checks apply to supported Workspace calls from trusted host code. They are
not a security boundary against code in the controller VM. Direct calls to VFS,
Shell, File, or OTP can bypass them. A raw path is for trusted host integration.
The local provider runs under the current OS user. It cannot restrict child
process access to host files or the network. Use an isolated provider before
running untrusted code.

## Migration from the local spikes

| Previous module | Current module |
| --- | --- |
| `Jido.Sandbox` | `Jido.Workspace.Sandbox` |
| `Jido.Deploy` | `Jido.Workspace.Deploy` |
| `Jido.Deploy.OTP` | `Jido.Workspace.Deploy.OTP` |
| `Jido.Deploy.Source` | `Jido.Workspace.Deploy.Source` |

The separate `:jido_sandbox` and `:jido_deploy` applications are removed. Their
nested modules use the same namespace change. There are no compatibility aliases.
File changes and close now return `:ok`. Update callers that expect a returned
Workspace handle. File errors now use `Jido.Workspace.Error`.

See [Sandbox](SANDBOX.md) for service ownership and provider limits.
See [Deploy](DEPLOY.md) for OTP migration, failure recovery, and Node.js
source deployment. OTP migration uses the current target state. A failed OTP
migration can restart the target and lose in-memory state.

## Checks

Run these commands from this folder:

```sh
mix deps.get
mix test
mix test.integration
mix format --check-formatted
mix compile --warnings-as-errors
```

The integration alias starts a separate BEAM instance for each example file.
The tests retain the Sandbox and Deploy scenarios and the existing Workspace
scenarios. Policy tests check file changes, raw handles, execution, deployment,
and modified environment handles.

The existing Workspace implementation and tests came from
`agentjido/jido_workspace` at `25f9fb6c65199c9180ffe6a83abdada4f565a508`.
The Apache 2.0 license is included in [LICENSE](LICENSE).

Command file views follow the active Shell backend. The built-in virtual backend
uses the Workspace VFS revision. Other backends report `kind: :backend`, the
backend module and session PID as owner, `path: :unknown`, and
`revision: :unavailable`. A local VFS revision cannot prove the state of remote
files. These backends accept `files: :current` and refuse pinned file views.

## Dependency checkouts

When sibling `jido_shell/` and `jido_vfs/` folders contain Mix projects, this
package uses them as local dependencies. Without those folders, it uses the
upstream Git revisions recorded in `mix.exs`. This supports both local stack
work and standalone CI checkouts.
