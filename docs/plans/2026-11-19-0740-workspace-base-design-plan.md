---
title: Workspace base design
type: implementation-plan
date: 2026-11-19
last_reviewed: 2026-11-19
artifact_contract: kata-plan/v1
artifact_readiness: planning-blocked
domain: software
execution: code
product_contract_source: direct-request
---

# Workspace base design

**Status** Draft for pressure testing. The project owner has reserved approval.
The contracts, implementation units, and test gates below are proposals.

The accepted [persistent infrastructure boundary](../decisions/2026-11-19-persistent-infrastructure.md)
governs future persistent providers. The host may reattach to the same resource
or request a fresh one. A persistent resource outlives its Workspace session.
After an interruption, the developer can inspect, wait for, or stop prior
commands. A new writer requires proof that the prior session cannot start
new work and its existing work can no longer write.

## Goal Capsule

- **Objective** Give an ordinary Elixir application one API to open a working
  directory, edit its files, run tools against those files, and save and
  reopen the tree.
- **Means** Bind one provider to one live tree. Use an OTP controller for live
  ownership and a separate store for immutable snapshots.
- **Authority** Write and review this plan. Implementation requires a separate
  request.
- **Stop conditions** The owner can trace the proposed API through normal and
  failure paths, challenge the tradeoffs, and approve or revise the decisions.
- **Next executor** The project owner reviews the draft. After approval and
  authorization, a maintainer implements the approved units.

## Product Contract

### Summary

Keep the package and module names. Make `Jido.Workspace` the entry point for
working files, commands, and durable snapshots. The base works in a Mix
application independently of Jido agent primitives.

### Problem Frame

Today a Workspace can expose a VFS tree while its execution backend observes a
different tree. The package also has an immutable in-memory capture and a
deployment payload. Neither is a workspace-level reference with a restart
recovery contract.

### Actors

- A host application chooses providers, toolchains, policy, and stores.
- A caller works with a live handle and can hand off a saved reference.
- The project owner approves the public contract, compatibility policy, and
  security and recovery guarantees.

### Requirements

| ID | Requirement |
| --- | --- |
| R1 | Each live workspace has one authoritative tree. File operations and commands see each other's completed writes. |
| R2 | The host chooses a named profile. Opening succeeds only after the provider meets its file, toolchain, and containment requirements. The caller uses one API across profiles. |
| R3 | Explicit save returns an immutable reference. The reference remains usable after close and, within the store's guarantee, after a BEAM restart. |
| R4 | The live workspace fits an OTP supervision tree. Close, owner exit, and failures have defined effects on work, cleanup, and saved content. |
| R5 | The base is usable without Jido at runtime. Services and Deploy can build on it with their own lifecycles. |

### Key Flows

- The host defines profiles. The caller opens an empty workspace or restores a
  snapshot, works against the live tree, and closes the workspace.
- The caller can save a quiescent tree and pass its reference to a fresh
  workspace or a later consumer.
- A failed profile check, restore, or cleanup reports the outcome without
  granting a new usable handle or falsely reporting that cleanup succeeded.

### Acceptance Examples

- The same script of write, command-read, command-write, file-read, save, close,
  and reopen passes on memory with virtual tools and on an isolated native
  provider. It uses only the Workspace facade.
- A fresh BEAM process opens a serialized reference and sees the saved bytes,
  empty directories, and supported modes. Edits made after the save are absent.
- If the selected provider cannot enforce a required restriction, opening
  fails. An execution that cannot be confirmed stopped cannot leave the
  workspace eligible for a snapshot.

### Success Criteria

A normal Mix application can use the base directly. The same-tree and restart
claims have executable evidence. The first provider pair has documented
capability limits. The owner has made the open decisions before work begins.

### Scope Boundaries

The candidate base covers profile resolution, live files and commands, explicit
save and restore, supervision, provider cleanup, and migration of the Workspace
facade. Host applications retain provider selection and fleet orchestration.
Separate follow-on work covers first-class services, direct Deploy consumption
of a saved reference, Python and Node toolchain profiles, interpreter embedding,
remote providers, automatic recovery, and Jido integration. Existing Shell,
VFS, Sandbox, and Deploy behavior is in the regression scope.

### Key Decisions

The product direction is one live tree, one host-selected profile, and an
independent saved reference. Technical defaults in this plan are candidates
for owner review.

### Rejected Alternatives

Periodic sync between two live trees cannot provide the proposed visibility
guarantee. An API that asks callers to assemble VFS, Shell, and Sandbox handles
makes callers responsible for the same invariant. A separate package or
application per toolchain would add an installation and lifecycle boundary to
the base workflow.

### Dependencies

Use the consolidated package at `b04f6dd`, its supported Elixir and OTP
versions, and its existing Shell and VFS modules. Native proof requires a
local, authorized runtime fixture that meets the approved profile policy.
The current Mix project uses Jido only for tests. [Mix project](../../mix.exs)

### Outstanding Questions

The project owner must confirm the first native trust boundary, the persistence
and close guarantees, and the Workspace API migration policy. See
[Open Planning Decisions](#open-planning-decisions).

### Sources

The direct request and preceding design discussion set the scope. The
[consolidation plan](2026-11-19-0700-consolidate-jido-workspace-plan.md) and
[asset lifecycle proposal](../workspace-asset-lifecycle.md) record earlier
decisions. This draft proposes a stronger same-tree contract and carries
forward explicit save and restart recovery.

## Planning Contract

### Product Contract Preservation

Product Contract unchanged. This draft records the agreed direction and marks
new API, storage, security, and cleanup details as proposals. It leaves the
previous plan and API specification as separate records.

### Current System

- `Workspace.open/1` creates an owner-monitored `Lifetime` GenServer. It
  configures a VFS, mounts it, and starts a Shell session on demand. The
  existing API takes absolute paths and a command string. Its `FileView` can
  identify a backend with an unavailable revision. [Facade](../../lib/jido_workspace.ex)
  · [Controller](../../lib/jido_workspace/lifetime.ex)
- The in-memory adapter captures a single tree state through its Agent.
  The virtual Shell dispatches file commands through the same mounted VFS.
  The capture carries content, and its live revision token is process-local.
  [InMemory adapter](../../lib/jido_vfs/adapter/in_memory.ex)
  · [Shell command runner](../../lib/jido_shell/command_runner.ex)
- Docker Sandbox mounts its owned directory at `/workspace`. An opt-in test
  exercises two-way file visibility. Its backend advertises container-scoped
  cancellation and currently reports `checkpoints: false`. That evidence
  supports the topology. It does not prove a consistent save or crash
  reclamation. `Sandbox.close/1` currently returns `:ok` without destroying the
  Sandbox. Destruction is a separate operation. [Docker backend](../../lib/jido_workspace/sandbox/backends/docker.ex)
  · [Docker test](../../test/examples/docker_sandbox_test.exs)
  · [Sandbox API](../../lib/jido_workspace/sandbox.ex)
- Deploy already has a target controller and uses supervised tasks. Its
  current snapshot conversion drops directory entries. Retain that payload
  boundary until the future handoff specifies which metadata Deploy preserves.
  [Deploy server](../../lib/jido_workspace/deploy/server.ex)
  · [Deploy snapshot](../../lib/jido_workspace/deploy/snapshot.ex)

### Target System

`Workspace.open(profile: name, from: ref)` resolves host configuration,
verifies the optional snapshot, provisions one private tree, and returns an
opaque handle once policy is in force. File operations and `run(ws, argv, opts)`
use the same provider binding. `save(ws)` publishes a reference to immutable
content. `close(ws)` releases the live lease.

The core caller uses `Workspace.t()` for live work and `Snapshot.t()` for saved
work. `Entry.t()` and `Execution.t()` are returned values. A live revision can
guard a checked operation, but its meaning ends with that live generation.
The saved digest identifies canonical content and grants no authority.

**Caller example for review**

```elixir
alias Jido.Workspace

{:ok, ws} = Workspace.open(profile: :files)

snapshot =
  try do
    :ok = Workspace.write(ws, "report.txt", "Draft\n")
    {:ok, %{exit_status: 0, output: "Draft\n"}} =
      Workspace.run(ws, ["cat", "report.txt"])

    {:ok, saved} = Workspace.save(ws)
    saved
  after
    Workspace.close(ws)
  end

{:ok, reopened} = Workspace.open(profile: :files, from: snapshot)
{:ok, "Draft\n"} = Workspace.read(reopened, "report.txt")
:ok = Workspace.close(reopened)
```

#### Batch steps and an optional builder

This is a follow-on API candidate. Keep named profiles for `open/1`. Use plain
Elixir values to describe a batch on an open workspace. Start with an ordered
list of `mkdir`, `write`, and argv-based `run` steps. Callers can make lists
with normal Elixir functions, concatenate them, and inspect them before use.

```elixir
steps = [
  {:mkdir, "out"},
  {:write, "out/report.txt", "Draft\n"},
  {:run, ["cat", "report.txt"], [cwd: "out"]}
]

{:ok, %{status: :completed, results: [:ok, :ok, execution]}} =
  Workspace.batch(ws, steps)

{:ok, snapshot} = Workspace.save(ws)
```

A builder could provide pipe-friendly functions that produce the same list.
Add it if callers need it to compose batches that they use often.

```elixir
alias Jido.Workspace.Batch

steps =
  Batch.new()
  |> Batch.mkdir("out")
  |> Batch.write("out/report.txt", "Draft\n")
  |> Batch.run(["cat", "report.txt"], cwd: "out")
  |> Batch.steps()
```

- Check step shape, paths, options, step count, and total request bytes before
  any step runs. Apply host limits to total run time and returned output. Use
  the same policy and provider operations as the direct API. Check conditions
  that depend on the live tree when each step runs.
- Reserve the writer slot until the batch finishes or stops. Competing writes,
  commands, and saves return `:busy`. Reads can observe intermediate files.
  The controller admits each step and uses supervised workers for provider
  calls. Close prevents admission of further steps and uses the provider's
  stop and cleanup rules for any active step.
- Stop on the first failed step or on a command that fails to exit with status
  zero. Return `{:ok, report}` for a batch with a known report. The report has
  status `:completed` or `:halted`, ordered results for completed steps, and,
  on halt, `failure: %{index: index, result: result}` with a one-based index
  and an `Execution` or `Error`. Return `{:error, error}` if the request cannot
  start or the report is unavailable. Earlier writes and writes made by the
  failed step can remain in the tree.
- Keep save explicit. If the provider cannot confirm that an active step has
  stopped writing, keep writes and saves blocked under the lease rules. A
  lost reply can leave partial effects. Leave retries to the caller.

Use ordinary Elixir control flow for branches or for commands that depend on
earlier output. Use a batch when the caller needs to pass an inspectable
sequence or reserve the writer slot across multiple steps. This candidate
uses the existing provider callbacks. Review it after the single-operation
and lease contracts are settled.

### Key Technical Decisions

| ID | Proposed choice and reason | Alternative and consequence | Governs |
| --- | --- | --- | --- |
| KTD1 | Let one provider bind the authoritative root and the runner. This makes file visibility a provider contract. | Separate caller-selected adapters would require a pairing protocol and could still expose two trees. | R1, R2 · U1, U3 |
| KTD2 | Validate a host profile once before publishing a handle. Check API authorization separately from runtime containment. | Per-call provider and security options would let a caller construct a weaker or inconsistent environment. | R2, R5 · U1, U3 |
| KTD3 | Capture a quiescent tree and atomically commit it to a separate, content-addressed store. Start with a bounded local directory store. | Live autosave and provider checkpoints have different writer, durability, and recovery semantics. They need separate evidence. | R3, R4 · U2 |
| KTD4 | Use a temporary GenServer for decisions and supervised workers for blocking operations. Bind cleanup to a lease identifiable before provisioning. | Automatically restarting the controller could give a handle a different tree. Cleanup confined to `terminate/2` would miss abrupt exits. | R2, R4 · U1, U3 |
| KTD5 | Add a profile-based route within the existing Workspace module. Keep compatibility until callers and tests have moved. Treat snapshots as the handoff type for future Deploy and keep release intent with the target. | Rewriting existing Sandbox and Deploy behavior as part of the base would expand the review and hide compatibility failures. | R1, R5 · U1, U4 |
| KTD6 | Prefer [`erlexec`](https://github.com/saleyn/erlexec) for OS process supervision inside native providers. It supplies process monitoring, output delivery, and process-group controls in one library. | Use the current Port-based runner as the baseline for comparison. The provider enforces containment and confirms when all writers have stopped. | R2, R4 · U3 |

### System Boundaries and Change Surface

**Host configuration candidate.** These are illustrative names and values.
The provider gets the resolved requirements and limits as inputs to
provisioning. It reports the effective guarantees for an explicit admission
check. A pinned toolchain image belongs to the provider options.

```elixir
config :jido_workspace,
  profiles: [
    files: [
      provider: {Jido.Workspace.Provider.Memory, []},
      tools: ["cat", "ls", "mkdir", "rm"],
      authorize: [:read, :write, :execute, :import, :save],
      require: [isolation: :mediated, network: :disabled, tree_access: :read_write],
      limits: [timeout_ms: 30_000, output_bytes: 1_048_576],
      store: "work_assets"
    ]
  ],
  stores: %{"work_assets" => {MyApp.DirectoryStore, root: asset_root}}
```

| Boundary | Candidate contract |
| --- | --- |
| Live handle | Opaque, scoped to one controller generation. The host authorizes profile and snapshot selection. The owner monitor controls lifetime. Handing out a handle conveys the operations its profile grants to trusted callers. A provider enforces a separate boundary for launched code. |
| Portable tree | Canonical workspace-relative paths, regular files, empty directories, and a regular or executable mode. Use relative `cwd:` and literal argv. An executable comes from the profile toolchain or workspace under its rules. Refuse ambiguous paths, unsupported entries, and restores the destination cannot represent. |
| Snapshot | `%Snapshot{store: binary(), format: pos_integer(), digest: binary()}`. The store hashes canonical content, publishes atomically, and verifies the digest on load. Resolve store IDs through trusted configuration. Keep credentials, environment, process state, and runtime revisions outside the reference. Files written into the saved tree are part of its content. |
| Safety | Authorize read, write, execute, import, and save separately. Apply the same write policy to file calls and native tools. Provider guarantees cover allowed roots, network, credentials, process cleanup, and resource limits. A profile must fail closed when enforcement cannot be established. Keep command output and errors bounded and exclude secrets from diagnostics. |
| Compatibility | Today the facade uses absolute paths, string commands, and raw handles. The candidate migration uses an explicit profile-based open, relative paths, and argv. Preserve existing behavior during transition, identify call sites, and require a separate owner decision before removing or reinterpreting an existing call. |

**Provider callback sketch.** Types here describe the boundary. They do not
prescribe a file backend or remote protocol.

```elixir
@type lease :: %{id: String.t(), controller: pid()}
@type tree :: %{optional(String.t()) => :directory | {:file, binary(), :regular | :executable}}
@type environment :: term()
@type result(value) :: {:ok, value} | {:error, Jido.Workspace.Error.t()}

@callback provision(lease(), profile_spec(), tree()) ::
            result({environment(), capabilities()})
@callback file(environment(), file_request()) :: :ok | result(file_value())
@callback run(environment(), command()) :: result(Jido.Workspace.Execution.t())
@callback capture(environment()) :: result(tree())
@callback release(lease(), provider_options()) :: :ok | {:error, Jido.Workspace.Error.t()}
```

`file_request()` covers read, write, list, mkdir, and delete. `command()`
contains a nonempty argv list, relative cwd, and bounded deadline and output.
`provision/3` restores into a private tree and reports enforced capabilities.
A successful `run/2` completion, including a confirmed timeout, means its
processes can no longer write. If it cannot confirm that state, it reports
`:quiescence_unknown`. The store has `put` and `fetch` operations for validated
trees and references. Start with host-configured bounds on tree bytes, entry
count, and retained command output. Check the restore budget before exposing a
live handle. Confirm where the native provider can enforce the live tree
budget in U3.

**Controller contract for providers with disposable roots.** Use a
`DynamicSupervisor` for controller lifetime and a `Task.Supervisor` for work.
Keep admission, job references, and state
transitions in the GenServer. Workers return tagged results. Match results to
the current task reference, handle `:DOWN`, and reply with `GenServer.reply/2`.
A caller's call timeout and a provider's execution deadline are separate
events. [OTP task pattern](https://hexdocs.pm/elixir/Task.Supervisor.html#async_nolink/3)
· [OTP replies](https://hexdocs.pm/elixir/GenServer.html#reply/2)

| Transition | Required outcome under this proposal |
| --- | --- |
| `:opening → :ready` | Monitor the owner and register the lease before allocation. Verify import authorization and content, provision, then check capabilities. Return the handle only after all checks pass. Open failure or cancellation revokes the lease, even if the provider has yet to return a handle. |
| `:ready → :saving → :ready` | Reserve the writer slot before work starts. If an admitted command or mutation can still write, return `:busy`. During save, fence new writers through capture and store commit. Release the fence on a determinate failure. Provider loss with uncertain writers closes the lease. |
| `:opening / :ready / :saving → :closing` | Refuse new work. Close during save waits for the accepted operation within its deadline. If save's reply is lost, the last known reference remains valid. The store may contain an unreferenced object. Release the provider only after it can fence live activity. |
| `:closing → stopped` | Return `:ok` only after confirmed release. On uncertainty, report `:cleanup_unconfirmed` and retain responsibility with the cleanup owner. A repeat close can use confirmed lease state. A dead controller alone gives no evidence of release. |
| Controller or BEAM loss | The old handle expires. The provider's cleanup owner must survive the controller. To claim recovery after a whole BEAM crash for an external resource, also prove reclamation through provider expiry or startup reconciliation. Run no implicit command retry. Recover from the last known snapshot. |

`release/2` must be safe when repeated and before a late provision response.
It fences new activity for the revoked lease, stops existing writers, then
reclaims the root. A deferred result from an earlier transition cannot publish
a handle or return the controller to ready after close. OTP can skip
`terminate/2` on abrupt exit. [OTP termination semantics](https://hexdocs.pm/elixir/GenServer.html#c:terminate/2)

### Implementation Units

#### U1 — Open and work on one memory tree

- **Requirements and dependency** R1, R2, R4, R5. Starts after approval of the
  contract that this unit uses.
- **Direction** Evolve the [facade](../../lib/jido_workspace.ex),
  [controller](../../lib/jido_workspace/lifetime.ex), and
  [application supervision](../../lib/jido_workspace/application.ex).
  Add profile validation and a memory provider over existing VFS and virtual
  commands. Dispatch argv directly. Preserve the existing string API during
  the transition. Handle owner exit during open and reject work while closing.
- **Proof and completion** Run direct file and command checks in both
  directions, including literal argv and cwd, unsupported tools, rejected
  profiles, and cleanup on abrupt owner exit. One public handle passes the
  same-tree contract and closes without leaving processes or mounts.

#### U2 — Save, close, and reopen after restart

- **Requirements and dependency** R3, R4. Requires U1 provider binding and
  writer admission.
- **Direction** Reuse the [VFS capture model](../../lib/jido_vfs/capture.ex)
  behind a provider-neutral codec. Add the snapshot reference and bounded
  directory store. Implement atomic publication, digest check, private
  restore, save fencing, and stable error outcomes.
- **Proof and completion** A new BEAM consumes a serialized reference.
  Equal canonical content gives the same digest within one format. Test
  when a command is still writing, interrupted and corrupt stores, close
  during save, and loss of the reply after commit. A failed attempt preserves
  prior references, and a partial object cannot open as a snapshot.

#### U3 — Prove the contract on one isolated native provider

- **Requirements and dependency** R1–R4. Requires U1 admission contract and U2
  capture and restore contract.
- **Direction** Adapt the [Docker Sandbox boundary](../../lib/jido_workspace/sandbox/backend.ex)
  where it meets the approved trust model. Reuse an owned root, native cwd,
  and provider process cleanup. Confirm profile admission, write enforcement,
  capture quiescence, and lease reclamation with the chosen disposable runtime
  fixture.
  Reject any configuration that weakens an approved guarantee.
- **Native process runner** Evaluate `erlexec` first against the
  [current local Port runner](../../lib/jido_workspace/sandbox/backends/local.ex).
  Keep it behind the native provider. Check the build on each supported
  platform before selecting a dependency version. Preserve direct argument
  passing, working directory, output limits, and exit status. Test process
  exit, timeout, and stop when a child process can still write to the tree.
  The provider must confirm that all writers have stopped. If `erlexec`
  launches a Docker client, the container lifecycle remains the Docker
  provider's responsibility. Remote providers own command identity and
  [recovery across BEAM restarts](../decisions/2026-11-19-persistent-infrastructure.md#recovery-and-write-access).
- **Proof and completion** Run the same facade suite as U1 and U2 with the
  native profile. Add negative containment tests and force late provision,
  a lost worker, and an unconfirmed stop. Verify resource inventory returns to
  baseline. A fixture that provides a weaker trust boundary leaves this gate
  open.

#### U4 — Integrate the base and verify package compatibility

- **Requirements and dependency** R1–R5. Requires U2 and U3.
- **Direction** Apply the approved compatibility decision at the
  [Workspace facade](../../lib/jido_workspace.ex). Update the README and API
  spec with demonstrated behavior. Preserve direct Shell, VFS, Sandbox, and
  Deploy tests. Show the saved reference crossing into a separate consumer
  while leaving the direct Deploy overload to follow-on work.
- **Proof and completion** Install from the Hex build in a fresh Mix project
  and run the core flow without Jido or sibling packages. Verify preserved
  caller behavior, normal package checks, and documented profile limits.

### Work Graph

The current frontier is owner review. After approval, the implementation
frontier is U1. U2 then proves the canonical capture and restore boundary.
U3 uses that boundary for native execution. U4 integrates and verifies the
installed package. The critical path is `U1 → U2 → U3 → U4`.

### Verification Contract

These are future execution gates. Use deterministic message barriers for
ordering tests and fault injection at allocation, capture, commit, reply,
and release boundaries.

| Gate | Coverage | Required evidence |
| --- | --- | --- |
| V1 · Shared tree and tool semantics | R1, R2 · U1, U3 | Bidirectional visibility, argv and cwd tests, entry equality, correct result for nonzero exit, and clear rejection of unsupported requirements. |
| V2 · Persistence | R3 · U2, U3 | Reopen by reference in a fresh BEAM. Verify exact portable content, rejected corruption, no partial publication, and the expected outcome on both sides of the store commit point. |
| V3 · Lifecycle and policy | R2, R4 · U1–U3 | Close and owner-exit tests, failure injection around worker and controller loss, no late handle, no snapshot while writer state is uncertain, confirmed cleanup, and defensive policy checks against the actual native fixture. |
| V4 · Install and preserve callers | R5 · U4 | Standard Mix checks and a fresh tarball consumer with no Jido dependency. Existing Workspace, Shell, VFS, Sandbox, and Deploy contract tests pass according to the approved compatibility policy. |

Run the repository gates from the `jido_workspace` Mix root. For V3, record the
local runtime and image identity and the containment features active in the
test. The native gate needs an authorized fixture. A skipped or downgraded
fixture supplies no evidence for the native guarantee.
[Mix aliases](../../mix.exs) · [CI package command](../../.github/workflows/ci.yml)

```sh
mix test
mix test.integration
mix test --include integration test/jido_vfs/adapter/{ets,git,in_memory,local}_integration_test.exs
mix quality
mix hex.build
```

**Pressure tests for owner review**

| Challenge | Expected behavior to approve or revise |
| --- | --- |
| The provider allocates a root after the open caller exits. | The same lease can release resources even when provision never returned. A late result cannot make the handle usable. |
| A timed-out process leaves a descendant that can write. | Keep writer state uncertain, refuse save, and revoke the lease. Recover by opening a known committed reference under a fresh lease. |
| Save races an in-flight file write or command start. | The controller reserves mutations before dispatch. Save either observes a completed writer or returns busy. No mixed capture. |
| Commit succeeds just before the BEAM stops or the reply is lost. | A reference already received is usable. A caller that lost both the reference and exact bytes cannot discover that save without a receipt mechanism. Decide whether the first consumer requires that mechanism. |
| Close times out, then the caller tries again with the same handle. | A call timeout alone proves neither cleanup nor failure. Resolve the retry through lease state or return cleanup uncertainty. |
| A snapshot fits memory but contains names the native tree cannot represent. | Fail restore before returning a handle. Preserve the stored object. Decide if the portable format should reject those names at save time. |
| The provider can run a tool but cannot enforce the requested file or network policy. | Refuse open. The controller's API checks do not substitute for provider enforcement. |
| The entire BEAM dies while Docker resources are live. | Establish how the host reclaims them by lease identity without a live controller. If the fixture cannot prove that, narrow the supported guarantee explicitly before approval. |

### Rollout and Recovery

Develop and verify behind explicit profile selection. Existing consumers keep
their current paths while the profile-based path is tested. If the candidate
fails conformance, withdraw the affected profile before expanding use and keep
its saved objects available for a compatible reader. A rollback must account
for references in the new snapshot format before removing that reader. Set
retention and cleanup policy before sharing a store across workloads.

### Risks and Assumptions

- The first tree representation buffers content. The proposed limits require
  tests with oversized input and concurrent work. A streaming format becomes a
  separate design if the first workload cannot fit useful bounds.
- A parent process exit or a Docker client's exit does not prove that every
  writer stopped. The existing test evidence covers a narrower path than the
  proposed lease contract.
- Same-host BEAM restart recovery assumes the store and its disk remain
  available. Power loss or host loss requires a separately tested guarantee.
- The store publication reply can be lost. Retrying `save/1` on a mutable
  tree can capture newer content. A retry of the exact canonical content
  can use its digest.

### Open Planning Decisions

| ID | Owner decision | Candidate and effect |
| --- | --- | --- |
| D1 | Project owner approves the public surface and compatibility path. | Use profile-based open and argv, with relative paths on the new route. Keep existing behavior through migration. Controls U1 and U4. |
| D2 | Project owner approves the first native threat model and required fixture. | Require enforced isolation for agent-authored native code. Select the actual runtime, restrictions, and resource limits before making the claim. Controls U1 profile admission and U3. |
| D3 | Project owner approves save format, bounds, retention, and the restart guarantee. | Start with explicit save, portable entries, same-host restart, and no operation receipt unless required. Decide path and mode validity and who can remove saved assets. Controls U2 and U3. |
| D4 | Project owner approves save/close interleaving and the cleanup boundary. | Start idle-only. Wait for an accepted save up to its deadline. Require proof of release for close success, and decide the scope of orphan reclamation after node loss. Controls U1–U3. |

The owner can accept or revise each candidate. Recheck any affected work unit
and gate before declaring the plan ready. The pressure tests above are review
cases for this draft. They are not evidence of provider conformance.

### Definition of Done

After approval and implementation, the same public workflow passes on memory
and the approved native profile. A saved reference reopens the exact
supported tree in a fresh BEAM. The lifecycle and containment tests cover
each failure promise, the installed package runs independently of Jido, and
the documentation states the supported profiles and limits. Current callers
are accounted for under the approved migration decision.

### Planning Sources

- [Workspace asset lifecycle proposal](../workspace-asset-lifecycle.md)
- [Current API specification](../../API_SPEC.md)
- [OTP application and supervisors](../../lib/jido_workspace/application.ex)
- [Policy and trusted caller scope](../../lib/jido_workspace/policy.ex)
- [Docker provider and capability report](../../lib/jido_workspace/sandbox/backends/docker.ex)
- [`erlexec` process execution and lifecycle documentation](https://github.com/saleyn/erlexec#summary)
- [GenServer](https://hexdocs.pm/elixir/GenServer.html)
- [Task.Supervisor](https://hexdocs.pm/elixir/Task.Supervisor.html)

## Adapter Results

- Markdown — canonical in `docs/plans/2026-11-19-0740-workspace-base-design-plan.md`
- HTML — not requested
- Beadwork — not requested
