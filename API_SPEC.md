# Workspace API proposal

Status: Workspace contracts and the first Sandbox backend increment are implemented.
Remaining Sandbox, Policy, Deploy, and production Action/Signal contracts remain proposed.
This package is unreleased. Update the existing API and its callers directly.
No versioned facade or compatibility layer is required.

## Implemented scope

`Jido.Workspace` uses `:ok` for write, mkdir, delete, stop_session, and close.
All Workspace methods return `Jido.Workspace.Error` on failure.
Its `resource` field is the Workspace ID.
The bounded cause is diagnostic text, not a second machine-readable contract.

The existing controller owns storage, resource lifetime, and policy. Keep the
same handle for its lifetime. It contains only ID and controller PID. `info`
returns current state. `list` returns Entry records. `replace` requires an
explicit expected revision. `run` returns an Execution with bounded combined
output, status, exit status, duration, and file observations. `new`, `snapshot`,
`restore`, `execute`, `workspace_id`, and `session_id` are removed.
Sandbox adds the Local and Docker backend contract below. Policy and Deploy APIs are unchanged.

`test/examples/workspace_file_api_test.exs` and
`test/examples/workspace_contract_test.exs` run real operations through direct
calls, shared test Actions, and AgentServer Signals. The broader Action/Signal
example also checks captures, commands, and deployment. Production Actions,
reference access, and schema/routing error replies remain later work. The `v1`
segment in Signal types identifies the message schema, not a separate API.

## 1. Ownership and boundaries

| Boundary | Owns | Does not own |
| --- | --- | --- |
| Workspace | Working files, VFS mounts, virtual Shell session, capture checks | Source history, OS services |
| Sandbox | Backend resource, execution, files, retained services | Source acceptance, deployment order |
| Policy | Permission decisions at controller boundaries | Backend capability or OS isolation |
| Deploy | Targets, ordered tasks, transition plans, operation evidence, recovery | Source history, build tools, acceptance |
| Actions | Input schemas, resource resolution, calls to the public API | A second implementation of file or deployment rules |
| Signals | Requests, correlation, progress, completion, failure | Permission grants or runtime handles |

Keep VFS, Shell, and source history separate. Keep Workspace and Sandbox files
separate. Transfer content explicitly. Loading a Studio project requires a root
with `mix.exs`; this does not restrict SDK file types.

The controller owns mutable state. Handles identify resources and remain stable.
Workspace close stops its storage and Shell session. The default Workspace owner
is the caller; owner exit closes it. Sandbox uses application ownership. Detach
leaves its resources intact; destroy removes them. Controller shutdown stops
local services. Remote lifetime guarantees must come from the selected backend.

## 2. Shared types and results

These are proposed types. Runtime handles are opaque to callers.

```elixir
@type resource_id :: String.t()
@type request_id :: String.t()
@type revision :: term()             # Opaque, bound to one resource generation
@type result(value) :: {:ok, value} | {:error, Error.t()}
@type mutation_result :: :ok | {:error, Error.t()}

# Proposed records, with required fields unless marked optional.
%ResourceRef{id: id, kind: :workspace | :sandbox | :deployment, generation: generation}
%Entry{path: path, kind: :file | :directory, mode: mode, size: size}
%FileView{resource: ref, path: path, revision: revision | :unavailable}
%Command{executable: executable, args: args, dir: dir, env: env,
         timeout_ms: timeout, output_limit: limit}
%Execution{id: id, status: :exited | :timed_out | :cancelled,
           exit_status: integer_or_nil, output: bytes, truncated: boolean,
           files: view, after_files: view_or_error, duration_ms: duration}
%Error{code: code, operation: operation, resource: ref_or_nil,
       message: message, details: map}
```

`output` is combined output in the first contract. A backend may supply separate
stdout and stderr through an optional output capability. Do not fabricate
separate streams from the current local provider's combined stream.

All paths use UTF-8. File bytes are binary. Workspace paths are absolute within
VFS. Sandbox paths are relative to the resource root. Reject parent traversal,
NUL, and unsupported links. No public portable operation requires a host path.
Timeouts use milliseconds. Limits use bytes. Enforce output limits at collection.

A command that starts and exits with a nonzero status returns `{:ok, execution}`.
Policy refusal, invalid input, unsupported operations, and failure to start return
`{:error, error}`. A command timeout returns an execution with `:timed_out`.
An observation error after execution must not hide completed side effects.

## 3. Workspace contract

```elixir
open(opts \\ [])                         # result(Workspace.t())
info(ws)                                 # result(Workspace.Info.t())
read(ws, path)                           # result(binary())
list(ws, path \\ "/")                    # result([Entry.t()])
write(ws, path, bytes)                    # mutation_result()
mkdir(ws, path)                          # mutation_result()
delete(ws, path)                         # mutation_result()
capture(ws)                              # {:ok, Capture.t(), revision()} | {:error, Error.t()}
replace(ws, capture, expected: revision)  # result(revision())
file_view(ws)                            # result(FileView.t())
run(ws, command_text, opts \\ [])         # result(Execution.t())
close(ws)                                # mutation_result(), idempotent
```

Options: `id`, `owner`, `policy`, `adapter`, `adapter_opts`, and `session_opts`.
Preserve the memory adapter default and the current full-access default during
migration. Agent hosts must select a policy explicitly.

```elixir
alias Jido.Workspace

{:ok, ws} = Workspace.open(policy: :workspace_write)
:ok = Workspace.write(ws, "/input.txt", "first")
{:ok, saved, _} = Workspace.capture(ws)
:ok = Workspace.write(ws, "/input.txt", "second")
{:ok, _current, revision} = Workspace.capture(ws)
{:ok, _next} = Workspace.replace(ws, saved, expected: revision)
{:ok, "first"} = Workspace.read(ws, "/input.txt")
:ok = Workspace.close(ws)
```

`replace` checks the resource generation and revision atomically with replacement.
It must refuse stale tokens. Captures contain immutable file content and survive
close. They do not contain process memory. Unsupported multi-mount captures
return an explicit error.

`run` uses the virtual Shell. It starts a session when required. A `files:` view
is a check before execution, not a file lock. `files: :current` observes current
files. A named view with an unavailable revision is refused. Backend file views
must describe the actual execution backend, not unrelated local VFS content.

Retain `filesystem`, `shell`, `start_session`, and `stop_session` as advanced
operations during migration. Raw handles require `:raw_handle` permission.
Controller state supplies current session information; handles do not cache it.

The implemented Workspace records are:

```elixir
%Jido.Workspace.Info{id: id, policy: profile, owner: pid, session: :running | :stopped}
%Jido.Workspace.Entry{path: absolute_path, kind: :file | :directory,
                      mode: mode_or_nil, size: bytes_or_nil}
%Jido.Workspace.FileView{kind: :workspace | :backend, owner: generation,
                         path: path, revision: revision | :unavailable}
```

The shared FileView retains its existing fields for Sandbox. Its Workspace
owner is the controller PID; backend views identify the backend and session PID.
Entry metadata that the VFS listing does not supply is `nil`.
`Execution.after_files` is a FileView or `{:error, Error.t()}`. It does not hide
a completed command when the final observation fails. `command` retains the
submitted text. `info.session` reports status without exposing a raw handle.

`start_session(ws, opts \\ [])` returns `{:ok, session_id}`. `shell(ws)` returns
the same ID. Both require raw-handle permission. `stop_session(ws)` returns
`:ok` and keeps files open. `filesystem(ws)` also requires raw-handle permission.

Run options are `files`, `timeout_ms` (default 30000), `output_limit` (default
1048576), and `execution_context`. Output limits apply during collection; zero
retains no bytes. A timeout cancels the current command. Shell start, syntax,
lookup, and runtime failures without an exit status return a structured error.
Shell network refusal returns `:policy_denied`. Shell diagnostics retain the
error category/code and omit command environment and context values.

## 4. Sandbox contract

Use profiles and backend capabilities as in
[LitterBox](https://github.com/zblanco/litter_box). This is a design reference,
not a promise of API compatibility or a new runtime dependency.

```elixir
alias Jido.Workspace.Sandbox
alias Jido.Workspace.Sandbox.Backends.Local

{:ok, sandbox} = Sandbox.open(backend: {Local, []}, policy: :full_access)
:ok = Sandbox.write(sandbox, "input.txt", "hello")
{:ok, command} = Sandbox.exec(sandbox, "/bin/cat", ["input.txt"])
"hello" = command.output
capabilities = Sandbox.capabilities(sandbox)
:ok = Sandbox.destroy(sandbox)
```

```elixir
open(opts \\ [])                         # result(Sandbox.t())
attach(resource_ref)                     # result(Sandbox.t()), capability required
detach(sandbox)                          # mutation_result(), does not destroy
destroy(sandbox)                         # mutation_result(), idempotent
info(sandbox)                            # result(Sandbox.Info.t())
capabilities(sandbox)                    # result(Capabilities.t())
read/list/write/mkdir/delete             # Same result rules; relative paths
file_view(sandbox, path \\ ".")          # result(FileView.t())
exec(sandbox, executable, args, opts \\ []) # result(Execution.t()); no implicit shell
start_service(sandbox, spec)             # result(ServiceRef.t())
service_status(sandbox, service_ref)      # result(ServiceStatus.t())
stop_service(sandbox, service_ref)        # mutation_result()
call(sandbox, service_ref, m, f, args, timeout_ms \\ 5_000) # result(term())
checkpoint(sandbox, opts \\ [])          # result(Checkpoint.t()), optional
restore(sandbox, checkpoint)             # result(ResourceRef.t()), optional
```

Named profiles select backend configuration and policy. Per-call options cannot
replace a profile's backend, resource identity, or permissions. Do not use a
public mutable struct as authority.

```elixir
config :jido_workspace, Jido.Workspace.Sandbox,
  profiles: [local_dev: [backend: {Local, []}, policy: :full_access]]

{:ok, sandbox} = Sandbox.open(profile: :local_dev)
```

### First backend increment: Local, Docker, and gVisor

Implement this contract before the remaining profile and remote contracts.
Keep existing `open()`, `provider: :local`, `close`, and the capability map return.
The result types in the method list above remain the later target where they
are different. This increment does not add profiles or production Actions.

```elixir
alias Jido.Workspace.Sandbox.Backends.{Local, Docker}

{:ok, local} = Sandbox.open(backend: {Local, []})
{:ok, box} = Sandbox.open(backend: {Docker, [image: "alpine:latest"]})
# gVisor uses the same Docker adapter. It must not fall back to runc.
{:ok, isolated} = Sandbox.open(backend: {Docker, [image: "alpine:latest", runtime: "runsc"]})
# Shorthands: provider: :docker or provider: :gvisor, with image: ...

:ok = Sandbox.write(box, "input.txt", "hello")
{:ok, %{output: "hello", exit_status: 0}} = Sandbox.exec(box, "/bin/cat", ["input.txt"])
%{provider: :docker, isolation: :container, cancellation: :container} = Sandbox.capabilities(box)
:ok = Sandbox.destroy(box)
```

Backend selection is trusted application configuration. The controller retains
backend state and capabilities. Modified public handle fields cannot change them.
`attach` returns the controller's handle. Action and Signal inputs contain only
resource references and command data; they cannot select a backend or mount.

The first backend behaviour supports execution over a controller-owned local
filesystem. All file access, policy checks, file views, service status, output
limits, and deadlines remain in the controller. Remote files need a later
contract extension. No arbitrary module/function invocation comes from a Signal.

```elixir
@type state :: term()
@type service :: map() # private port handle and optional backend resource ID
@callback open(Sandbox.t(), keyword()) :: {:ok, state(), map()} | {:error, term()}
@callback start_service(state(), map()) :: {:ok, service()} | {:error, term()}
@callback finish_service(state(), service(), integer()) :: {:ok, service()} | {:error, term()}
@callback stop_service(state(), service()) :: :ok | {:error, term()}
@callback destroy(state()) :: :ok | {:error, term()}
```

`start_service` returns a running service with a port or BEAM peer handle. The
controller collects combined output and exit messages. `finish_service` checks
the backend result after the client port exits. Docker reads the container exit
code; an OCI start failure is an API error and its container is removed. A
retained service can return its ID before the container starts. Query its status
to observe start failure. Backend cleanup must
stop the whole owned execution resource before it reports success. Cleanup
errors must be returned. A failed start must remove resources it created.
`destroy` also finds resources from a partial start. Resources use the Sandbox
ID as an ownership label. No cleanup command can prune unrelated resources.

Docker requires a local Unix-socket Linux engine and an installed image. The
engine endpoint is fixed at open for execution and cleanup. It
resolves the image to its immutable ID at open. It never pulls an image. Each
`:exec` service gets a separate container and shares only the owned root at
`/workspace`. Image-layer changes do not persist. The root filesystem is read
only; `/tmp` is temporary. Roots with comma, quote, or newline characters
are refused because the mount argument uses CSV syntax. Network is disabled. All Linux capabilities are
removed, privilege escalation is disabled, and CPU, memory, and PID limits are
fixed. Commands use the controller user's numeric UID and GID. Image entrypoints,
health checks, and implicit shells are disabled. Image-declared volumes are
refused. Container services must stay in the foreground.

Docker supports command services, attach within the controller VM, local file
views, and whole-container cancellation. It does not support BEAM calls,
checkpoints, tunnels, stdin, PTY, or separate output streams. gVisor requests
`runsc` explicitly and reports `isolation: :gvisor` only when selected. An
unavailable runtime is an error. There is no automatic provider fallback.

Errors for this increment retain Sandbox's existing `{:error, reason}` shape:

| Reason | Meaning |
| --- | --- |
| `:unsupported_provider` | Invalid provider or backend selection |
| `:invalid_backend_options` | Unknown or invalid backend option |
| `{:backend_unavailable, :docker, detail}` | CLI, engine, or local endpoint unavailable |
| `{:image_unavailable, image}` | Image is not installed |
| `{:runtime_unavailable, runtime}` | Engine does not advertise the selected runtime |
| `{:unsupported_capability, capability}` | Backend cannot perform the operation |
| `{:start_cleanup_failed, error, cleanup_error}` | Start failed and cleanup needs another attempt |
| `{:docker, operation, status, output}` | Bounded Docker command failure |
| `{:docker, operation, :output_limit, output}` | Control response exceeds the buffer; effects can be uncertain |
| `{:docker, operation, :timeout, output}` | Command deadline expired; effects can be uncertain |

Do not treat nonzero command exit as an API error. It is an execution result.
A timeout returns `status: :timed_out`, `exit_status: 124`, after cleanup succeeds.
Explicit stop preserves `:stopped`; late exit messages cannot change it.

Migration: existing Local callers retain their behavior. New callers can use
`backend: {Local, []}` or `{Docker, opts}`. Keep `capabilities/1` as a map and
`close/1` as a detach operation in this increment. A backend tuple and a provider
shorthand cannot be supplied together. Named profiles, remote files, structured
Sandbox error records, checkpoint groups, and production Actions remain later
work. Tests use the same test Action and Agent Signal route for both providers.

Live acceptance: run direct commands, file transfer, bounded output, nonzero
exit, timeout, service stop, detach/attach, policy refusal, stale file views,
Action execution, and Agent Signal execution. Check container labels and mounted
paths. Check failed start and controller shutdown cleanup. Assert no containers
or owned roots remain after destroy. Require an explicit live-test flag; do not
silently report a missing engine as a pass. If `runsc` is installed, run the
same contract with it. Otherwise test runtime refusal and report that limitation.

## 5. Policy contract

```elixir
validate(profile)                    # mutation_result()
authorize(policy, %Request{})         # mutation_result()

%Request{action: :read | :write | :execute | :deploy | :raw_handle,
         resource: resource_ref, path: optional_path}
```

Keep `:read_only`, `:workspace_write`, and `:full_access`. Restricted profiles
continue to refuse all commands. They cannot safely infer command effects.
Cleanup remains available under all profiles. A command may reduce limits; it
cannot increase permissions. Permission and backend capability are separate
checks. Refuse requested restrictions that a backend cannot enforce.

The controller stores policy. Actions and Signals pass through the same checks
as direct callers. Signal `source` and a resource ID are not authentication.
Trusted host context determines which resources a caller can resolve. The Local
backend has the current OS user's permissions; these API checks do not create
OS isolation.

## 6. Deploy contract

Adopt named tasks, stages, roles, and ordered hooks from
[Capistrano](https://github.com/capistrano/capistrano) and its
[deployment flow](https://capistranorb.com/documentation/getting-started/flow/).
Do not require Git or SSH. Sandbox performs all target operations.

```elixir
Target.new(name: name, sandbox: sandbox, path: path, stage: stage, roles: roles)
# result(Target.t())
Recipe.new(strategy: :source | :otp, tasks: tasks, hooks: hooks)
# result(Recipe.t())
Deploy.connect(target)                # result(Deployment.t())
Deploy.inspect(deployment)            # result(Observation.t())
Deploy.prepare(deployment, artifact, opts \\ []) # result(Plan.t())
Deploy.apply(deployment, plan)        # result(operation_id())
Deploy.status(deployment, operation_id) # result(Operation.t())
Deploy.await(deployment, operation_id, timeout_ms \\ 30_000) # result(Operation.t())
Deploy.recover(deployment, operation_id, artifact, opts \\ []) # result(Plan.t())
```

Keep `Snapshot.new`, `Snapshot.from_directory`, and `Artifact.new`. A Snapshot
has a caller-supplied source ID, content digest, and relative file entries. An
Artifact has kind, version, and Snapshot. Neither owns source history.

```elixir
{:ok, recipe} = Recipe.new(
  strategy: :source,
  tasks: [build: {MyApp.DeployTasks, :build, []},
          restart: {MyApp.DeployTasks, :restart, []}],
  hooks: [{:before, :publish, :build}, {:after, :publish, :restart}]
)

{:ok, deployment} = Deploy.connect(target)
{:ok, plan} = Deploy.prepare(deployment, artifact,
  recipe: recipe, stage: :staging, roles: [:web])
{:ok, operation_id} = Deploy.apply(deployment, plan)
{:ok, record} = Deploy.await(deployment, operation_id)
```

The default order is check, stage, prepare, publish, verify, finish. Tasks are
trusted registered callbacks or Actions, not module names from Signal data.
A task receives `%TaskContext{target, artifact, operation_id, step_id, sandbox}`
and returns `{:ok, evidence_map}` or `{:error, Error.t()}`. Action tasks use
`Jido.Exec.run/4` and the same context. Retry is disabled unless the task has an
explicit safe retry contract. Verification failure is an execution failure.

`prepare` resolves hooks, validates cycles, selects roles/stage, checks required
capabilities, and records target observations. It performs no staging commands
or deployment writes. The exact ordered steps and callback identities enter the
stored plan. Apply refuses changed plans and stale target generations. Stage or
role mismatch is an error, not a successful empty deployment. The first version
supports one target per plan; fleet scheduling remains later work.

`Plan` contains ID, target, artifact, expected observations, ordered steps,
strategy, and optional recovery link. `Operation` contains ID, plan ID, status,
step evidence, before/after observations, and optional recovery link. Status is
`:running`, `:succeeded`, `:failed`, or `:recovery_required`.

Reapplying a retained plan returns the same operation ID. Await timeout does not
cancel execution. Records stay in controller memory; crash-safe exactly-once
execution is not provided. Keep canonical target ownership and generation checks.

Source strategy uses release directories, `current`, and `shared`. Publication
and restart can cause downtime and reset process state. Files-only projection
does not claim runtime activation. OTP strategy uses release instructions and
explicit `code_change/3` migration of the target's current state. Module loading
affects all process instances on that node. Branch state is evaluation input,
not a replacement for current target state. A failed transition can require
explicit recovery and can restart the node. Do not claim state preservation then.

## 7. Jido Action boundary

Direct methods are canonical. Each Action validates parameters, resolves trusted
resource references, calls one method, and maps the result. The controller still
validates every operation. Actions must not copy policy or deployment logic.

Proposed namespace: `Jido.Workspace.Actions` with `Workspace`, `Sandbox`, and
`Deploy` groups. Each operation has its own Action and schema. Example modules:

| Action suffix | Parameters in addition to request/resource IDs | Result data |
| --- | --- | --- |
| `Workspace.Write` | path, content, encoding | path |
| `Workspace.Read` | path | path, content, encoding |
| `Workspace.Capture` | none | capture_ref, revision_ref |
| `Workspace.Replace` | capture_ref, revision_ref | revision_ref |
| `Workspace.Run` | command, optional file_view_ref | execution |
| `Sandbox.Exec` | executable, args, allowed command options | execution |
| `Deploy.Prepare` | artifact_ref, recipe_ref, stage, roles | plan_ref, step summaries |
| `Deploy.Apply` | plan_ref | operation_id |
| `Deploy.Status` / `Deploy.Await` | operation_id, optional timeout_ms | operation |
| `Deploy.Recover` | operation_id, artifact_ref, recipe_ref | plan_ref |

File content uses UTF-8 or base64 with an explicit encoding. Large content uses
host-managed artifact references and size limits. Revision/capture/plan refs
resolve in trusted controller storage and are bound to a resource generation.
They are not untrusted serialized Erlang terms.

```elixir
{:ok, result} = Jido.Exec.run(
  Jido.Workspace.Actions.Workspace.Write,
  %{request_id: "req-1", resource_id: "draft", path: "/input.txt",
    content: "hello", encoding: "utf8"},
  %{workspace_access: trusted_access},
  max_retries: 0
)
```

Success returns `{:ok, %{request_id: id, resource_id: id, result: map}}`. Failure
returns a Jido Action error with the domain Error retained in its details. An
adapter must also support the trusted access value in `context.state`, because
the direct Agent strategy supplies Agent state there. No resource handles,
permissions, backend choices, callback modules, or reply destinations come from
model-supplied parameters. Open/attach require host-registered profiles. Apply
requires access to that exact stored plan; it does not imply source acceptance.

Actions run in executor tasks. The host must open resources under a persistent
owner before passing references to Actions. Do not create a caller-owned
Workspace in a short-lived Action task.

## 8. Jido Signal boundary

Use versioned request names and explicit routes:

```elixir
signal_routes: [
  {"jido.workspace.v1.workspace.write.requested", Actions.Workspace.Write},
  {"jido.workspace.v1.sandbox.exec.requested", Actions.Sandbox.Exec},
  {"jido.workspace.v1.deploy.prepare.requested", Actions.Deploy.Prepare},
  {"jido.workspace.v1.deploy.apply.requested", Actions.Deploy.Apply}
]

request = Jido.Signal.new!(
  "jido.workspace.v1.workspace.write.requested",
  %{request_id: "req-1", resource_id: "draft", path: "/input.txt",
    content: "hello", encoding: "utf8"},
  source: "/studio/agent/author"
)
Jido.AgentServer.call(agent, request)
```

The Signal adapter supplies the same Action parameters and trusted context.
`AgentServer.call` acknowledges Agent processing, not deployment completion.
The adapter sends a correlated reply through a host-selected Jido dispatch or
Signal Bus destination. Direct Action calls need no Signal transport.

Replies use the same operation prefix with `.succeeded` or `.failed`. Data has
`request_id`, `resource_id`, `causation_id` (the input Signal ID), and either
`result` or `error`. Signals carry serializable data, not PIDs, handles, secrets,
full snapshots, or function values. Validation/routing refusals also require
correlated failure replies from the adapter, before Action execution.

Deploy apply success means the operation was accepted. Execution progress uses
`jido.workspace.v1.deploy.operation.updated`, with operation ID, plan ID, step ID,
and status. A final update reports terminal status. Status queries remain the
authority if a Signal is lost. Request IDs provide correlation only. Duplicate
delivery does not make arbitrary commands safe to repeat. Disable automatic
retries for writes/commands; only retained Deploy plans have the stated apply
deduplication contract. No durable request history is added in this change.

## 9. Errors

| Code | Meaning | Retry rule |
| --- | --- | --- |
| `:invalid_input` | Invalid path, schema, options, or reference | Correct input |
| `:resource_not_found` / `:closed` | Missing resource or closed generation | Resolve or open explicitly |
| `:policy_denied` | Host/controller refused permission | Do not retry |
| `:unsupported_capability` | Backend cannot perform the operation | Select a suitable profile |
| `:unversioned_file_view` | Named file view has no checkable revision | Use explicit current observation or isolated files |
| `:stale_revision` / `:stale_file_view` / `:stale_generation` | Observed resource changed | Observe and prepare again |
| `:not_found` / `:already_exists` | File operation conflict | Inspect files |
| `:not_directory` / `:directory_not_empty` | Directory operation conflict | Inspect the path and its contents |
| `:operation_failed` | Other file API failure; bounded cause retained | Inspect effects before retry |
| `:busy` / `:target_conflict` | Target ownership or operation conflict | Inspect status |
| `:invalid_plan` | Plan changed or unknown | Prepare a new plan |
| `:start_failed` / `:backend_unavailable` | Execution could not start or connect | Inspect effects before retry |
| `:await_timeout` | Wait ended; operation can still run | Query the same operation |
| `:recovery_required` | Target state needs an explicit transition | Inspect and prepare recovery |

Errors include operation and resource identity where available. Preserve the
underlying cause in bounded details. Redact credentials and command environment
values. Do not mark an uncertain operation as safe to retry.

## 10. Migration and acceptance

1. Add this proposal and current-API integration evidence. No runtime API change.
2. Update Workspace methods in place with shared results/errors. Update repo
   callers and tests in the same change. Keep each method change small.
3. Add Policy requests and controller checks. Preserve current preset behavior.
4. Extract Local and add Docker behind the mounted-files backend contract. Run
   Local and live Docker tests, including capability refusal. Add named profiles
   and remote file contracts in a later increment.
5. Add Deploy tasks and ordered hooks. Retain source and OTP strategy behavior.
6. Add production Actions, Signal routes, reference storage, and error replies.
   Run the same behavior scenarios through direct calls, Actions, and Signals.
7. Remove redundant method names as their replacement contracts are implemented.
   Update callers directly; do not add compatibility facades.

| Existing call/result | Migration |
| --- | --- |
| `new` | `open`, always `{:ok, handle}` |
| `{:ok, ws}` after write/mkdir/delete/close | `:ok`; keep the original handle |
| `list` returns names | `Entry` records; use `entry.path` |
| `snapshot` / `restore` | `capture` / checked `replace` |
| `replace(ws, token, capture)` | `replace(ws, capture, expected: token)` |
| `run` / `execute` return handle | One `run` result record |
| `last_command` / cached session ID | Command result / controller info |
| `workspace_id(ws)` / `session_id(ws)` | `info(ws).id` / explicit `shell(ws)` result |
| `start_session` returns handle | `{:ok, session_id}`; keep the same handle |
| `stop_session` returns handle | `:ok`; keep the same handle |
| command `timeout:` | `timeout_ms:` |
| `Sandbox.open(provider: :local)` | `backend: {Backends.Local, []}` or profile |
| `Sandbox.close` | `detach`; retain alias during migration |
| `sandbox.root` | Relative file calls or explicit Local host-path capability |
| `source_target` / `OTP.start` | Validated target plus explicit strategy; retain bootstrap support |
| `%Recipe{prepare, service, verify}` | Named tasks and ordered hooks |
| Atom/tuple errors | Shared Error with original cause retained |

Change existing arities and result shapes directly when required. Update the
repo callers, examples, and tests in the same change. The package has no Hex
release that requires compatibility support.

## 11. Executable evidence in this change

`test/examples/action_signal_boundary_test.exs` uses real Jido Actions,
`Jido.Exec`, Jido Signals, an AgentServer, and PID Signal dispatch. It uses real
memory files, a Local Sandbox command, and a files-only deployment. Test-only
adapters normalize current results and store opaque references. No model is used.

The tests check file roundtrip, immutable capture, stale replacement refusal,
policy refusal, resource-bound reference checks, stale command-view refusal,
command output, preparation before activation, stored plan apply
identity, operation evidence, correlated replies, and cleanup. They do not prove
recipe hooks, production reference access,
durable Signal delivery, or proposed Sandbox/Deploy method return shapes. Those are later acceptance
tests, not skipped or simulated successes in this change.

`workspace_contract_test.exs` also checks directory records, controller info,
checked replacement, file views, raw access, session stop/start, output limits,
timeout cancellation, and nonzero exit output through all three boundaries.
They also check explicit cancellation and final file observation failure.
The nonzero case uses a test Shell backend that executes a real `/bin/sh`
process. Other Workspace commands use the virtual Shell. Test replies use
resource-bound references for captures, revisions, file views, and raw handles.

The test adapter supports UTF-8 text only and resolves pre-opened resources.
It sends replies for calls that reach an Action. Correlated schema/routing
failure replies and production reference access remain future adapter work.
The test Agent sets instruction `max_retries: 0` in `on_before_cmd/2`; the Jido
executor's default retries would otherwise repeat effectful calls and replies.

Run from `jido_workspace`:

```sh
mise exec -- mix test.integration
mise exec -- mix test
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
```

Jido is a test-only dependency at this stage. The core runtime remains usable
without an Agent runtime. Production integration must declare Action and Signal
dependencies explicitly, with Agent runtime support optional.

`docker_sandbox_test.exs` checks the Local/Docker backend boundary with a real
Docker engine. It checks files, exact arguments, environment, exit codes, output
limits, container settings, timeout, descendant cleanup, retained service stop,
caller exit, attach, controller shutdown, policy, stale views, missing images,
OCI start failure, Jido Actions, and correlated Agent Signal replies. Set
`JIDO_SANDBOX_DOCKER=1` to run it. Tests assert cleanup with ownership labels.
The same file uses runsc when available; otherwise it checks refusal only.
