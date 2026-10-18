# Workspace Deploy

A local deployment SDK with a Capistrano-style flow: named targets, staged
payloads, ordered preparation, activation, verification, and explicit recovery.
It supports OTP releases first and Node.js source deployment second.

Deploy uses `Jido.Workspace.Sandbox` inside the `jido_workspace` package.
Workspace policy controls deployment. There is no dependency on BeamWeaver or an
agent framework. VFS and Shell remain separate package dependencies.

## Boundaries

| Object | Purpose |
| --- | --- |
| `Snapshot` | Relative paths, file bytes, normalized modes, source ID, content digest |
| `Artifact` | Versioned source payload or OTP release payload |
| `Target` | Name, stage, roles, sandbox, destination path, and optional BEAM service |
| `Recipe` | Source preparation commands, service specification, verification command |
| `Plan` | Exact payload and expected target identity; separate from source history |
| Operation record | Actual steps, results, before/after observations, and recovery link |

Callers own source acceptance, build tools, and behavior contracts.
Workspace owns deployment permission checks. Deploy checks content identity and target conditions. It does not
claim that arbitrary source is safe or correct.

## OTP release upgrade

The caller supplies a release tree with this form:

```text
lib/counter_demo-2/ebin/
  counter_demo.app
  counter_demo.appup
  *.beam
releases/2/
  counter.rel
  start.boot
  sys.config
  relup
```

The initial version does not need `relup`. Upgrade packages contain `.appup`
and `relup` files made for the supported old versions. The spike uses installed
ERTS and OTP libraries on the same host. ERTS versions must match. Custom boot
scripts can use the `DEPLOY_LIB` boot variable for the target's `lib` directory.
The integration fixture shows `systools.make_script` and `systools.make_relup`.

```elixir
alias Jido.Workspace.Deploy
alias Jido.Workspace.Deploy.{Artifact, OTP, Snapshot}

{:ok, sandbox} = Jido.Workspace.Sandbox.open()
{:ok, initial_files} = Snapshot.from_directory("/absolute/releases/counter-1",
  id: "accepted-source-1")
{:ok, initial} = Artifact.new(:otp, "1", initial_files)
{:ok, target} = OTP.start(sandbox, "counter", initial, stage: :test)
{:ok, session} = Deploy.connect(target)

{:ok, next_files} = Snapshot.from_directory("/absolute/releases/counter-2",
  id: "accepted-source-2")
{:ok, next} = Artifact.new(:otp, "2", next_files)
{:ok, plan} = Deploy.prepare(session, next)
{:ok, operation_id} = Deploy.apply(session, plan)
{:ok, record} = Deploy.await(session, operation_id)
record.status
# :succeeded, :failed, or :recovery_required
```

The executor stages and verifies files, refuses conflicting existing bytes, and
registers the release with `release_handler.set_unpacked`. A small Erlang target
component runs `check_install_release` and `install_release`. It does not require
Elixir on the target. It has a runtime generation token and a single transition
lock. Target operations have stable IDs within that runtime generation.

Optional `preflight: {module, function, args}` and `verify: {module, function, args}`
callbacks run on the target and must return `:ok`. Preflight checks must have no
side effects. A preflight refusal occurs before code installation. Verification
runs after installation and checks the destination release and runtime generation.

State migration belongs in explicit OTP `code_change/3` callbacks and `.appup`
instructions. Traffic can continue after planning. OTP supplies the state that
exists when it performs the transition. The counter test proves that requests
after planning are preserved. It tests both upgrade and downgrade migration.

The SDK does not make a release permanent. Normal restart boots the initial
permanent release. Persistent boot selection and ERTS replacement are later work.

## Failure and recovery

`apply/2` returns an operation ID immediately. Reapplying the same stored plan
returns that ID. Modified plans are refused. Each destination has one controller
and one active operation. A stale target identity is refused before activation.

`await/3` timing out does not cancel execution. Query `status/2` again. Results
include source ID, digest, target labels, version, timed step evidence, and runtime
observations. Status stays available while the operation runs.

An uncertain installation result, failed verification, or a failed migration
after loading requires recovery. Further ordinary deployments are blocked.
Recovery is a new plan, linked to an earlier operation:

```elixir
{:ok, recovery} = Deploy.recover(session, operation_id, initial)
{:ok, recovery_id} = Deploy.apply(session, recovery)
{:ok, recovery_record} = Deploy.await(session, recovery_id)
```

A downgrade requires a valid downgrade path and state migration. It does not
reverse external effects. Failed recovery leaves the controller blocked.

OTP can restart the node after an installation error. This loses PIDs and
unsaved process state. Call `OTP.reconnect(target)` after the release applications
have restarted, inspect the new generation, then prepare explicit recovery.
The callback failure test proves this behavior. It does not report a state reset
as state preservation.

## Source deployment and Node.js

Source deployment uses this layout within the sandbox:

```text
node-app/
  releases/<operation-id>/
  current -> releases/<operation-id>
  shared/
  .service
```

Each operation writes a new directory, so removed source files do not remain in
the next release. Shared content stays outside snapshots. The spike reserves
`shared/`; automatic shared-file links and release retention are later work.

```elixir
alias Jido.Workspace.Deploy.{Artifact, Recipe, Snapshot}

{:ok, files} = Snapshot.from_directory("/absolute/node-app", id: "source-42")
{:ok, artifact} = Artifact.new(:source, "42", files)
{:ok, target} = Jido.Workspace.Deploy.source_target(sandbox, "node-app",
  stage: :test, roles: [:web])
{:ok, session} = Jido.Workspace.Deploy.connect(target)

recipe = %Recipe{
  prepare: [{"node", ["--check", "server.js"]}],
  service: %{executable: "node", args: ["server.js", "4001"]},
  verify: {"node", ["verify.js", "4001"]}
}

{:ok, plan} = Jido.Workspace.Deploy.prepare(session, artifact, recipe: recipe)
{:ok, operation_id} = Jido.Workspace.Deploy.apply(session, plan)
{:ok, record} = Jido.Workspace.Deploy.await(session, operation_id)
```

Commands can also use `{executable, args, options}`. Options include `env`,
`timeout`, and `output_limit`. Preparation may create build files or install
dependencies. It cannot change captured source bytes or modes. Output can contain
application data; callers must choose what they retain or expose.

Activation stops the previous service, switches `current` by rename, starts the
new service, then runs verification. There can be downtime. Node.js in-memory
state resets on restart. A failed preparation leaves `current` unchanged. A
failure after activation requires explicit recovery; no automatic rollback is
claimed. Recovery deploys the selected old payload into a new release directory.

Omit the recipe for files-only projection. It switches the file pointer without
stopping an existing service and reports `state_policy: :files_only`. This does
not claim that a running application uses the new files.

## Scope

The implementation is local and POSIX-only. It does not provide OS security
isolation. Use trusted payloads, boot scripts, commands, and upgrade instructions.
The SDK does not require an external version-control system.

Snapshot identity is distinct from content digest. A caller can retain its own
BeamWeaver source ID. A later VFS adapter can create snapshots without adding a
VFS runtime dependency. Captures support regular and executable files. Symlinks
and special files are refused; empty directories are not retained.

Plans and operation records stay in controller memory. Target operation records
stay in target memory. Controller or node loss requires inspection; exactly-once
execution across crashes is not provided. Destroying a sandbox also ends its
deployment controller. Closing a sandbox handle leaves its services running.

Stages and roles are labels in this spike. Multi-host execution, remote attachment,
SSH/SFTP, FTP, containers, provider plugins, durable journals, automatic pruning,
general task hooks, and BeamWeaver integration are later work.

## Tests

Use the versions in `mise.toml`. Review and trust the file with `mise trust`.

```sh
mise exec -- mix deps.get
mise exec -- mix test
mise exec -- mix test.integration
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
```

Each `test/examples/` file has the `:integration` tag. The alias runs each file
in a separate BEAM instance. The examples need no remote account, model, or
package download. The Node.js fixture uses built-in Node modules only.

## Provider boundary

Target identity is resolved by Sandbox. Equivalent paths share one deployment
controller. Target file operations and OTP release-file setup go through Sandbox.
The local provider supplies those operations; no remote provider is included.
Source preparation and verification command results include their input file
views. These views describe the actual staged directory at command start. They
remain separate from the accepted source snapshot identity.

Deployment controllers claim a generation for the canonical target ID in Sandbox.
Each worker uses that generation for file, service, and BEAM control requests.
Sandbox checks the generation and the controller PID before each operation.
A dead controller or an older generation returns `:stale_deployment`. The check
and operation use one Sandbox server call. A replacement controller cannot claim
ownership during that call. Generations stay in Sandbox memory.

A command or OTP transition that Sandbox has already accepted can still finish.
Ownership does not reverse its effects. Inspect the target after controller loss.
The OTP target still controls concurrent transitions and state migration.
