---
title: Consolidate Jido Workspace
type: implementation-plan
date: 2026-11-19
last_reviewed: 2026-11-19
artifact_contract: kata-plan/v1
artifact_readiness: implementation-ready
domain: software
execution: code
product_contract_source: direct-request
---

# Consolidate Jido Workspace

## Goal Capsule

- **Objective** Build one self-contained `jido_workspace` package from the three current codebases, then design its public API around the full lifecycle of workspace assets.
- **Means** Import pinned Shell and VFS source, prove existing behavior in one application, then review an API and durability contract against the combined code.
- **Authority** This request authorizes this plan document. The future implementation is scoped to `jido_workspace`.
- **Stop conditions** The stand-alone package passes the consolidation gates and a lifecycle design is ready for owner review. The lifecycle design requires approval before implementation.
- **Next executor** A maintainer working in the `jido_workspace` repository.

## Product Contract

### Summary

Ship source from Workspace, Shell, and VFS as one unreleased Hex package named `jido_workspace`. Preserve the existing capability set during import. Use the combined code to shape one public surface for opening a workspace, working with it, and keeping its assets beyond the live workspace.

### Problem Frame

The host currently coordinates three dependency graphs and process trees. It can keep a capture value after the workspace closes, but it has no workspace-level contract for saving and reopening assets after a node restart.

### Actors

- The package maintainer imports and tests the combined source.
- Host applications open workspaces and manage their files, execution, and saved assets.
- The project owner reviews the lifecycle design and owns future deprecation decisions.

### Requirements

| ID | Requirement |
| --- | --- |
| R1 | Ship the current Shell and VFS code inside `jido_workspace` as one Mix project and OTP application. Preserve behavior through the import. |
| R2 | Treat `jido_shell` and `jido_vfs` as read-only import sources. Leave deprecation and downstream migration to the owner. |
| R3 | After import, design one supported Workspace surface for opening, editing, executing, saving, closing, reopening, and handing off assets. Saved assets must outlive the live workspace. |
| R4 | Keep existing Jido contracts in test scope. Defer an agent plugin and any new Jido runtime dependency. |

### Key Flows

- Consolidation goes from pinned source to a stand-alone installation, then through a restored set of behavior and package checks.
- The proposed lifecycle goes from open to edit and execute, then to save, close, and reopen by a stable reference. The same saved asset can supply a later handoff.

### Acceptance Examples

- Install the local package tarball in a project without sibling checkouts. It can open a workspace, edit files, run a virtual command, capture files, run a local Sandbox command, and close.
- The lifecycle design explains how a caller can save a set of files, stop the owner and BEAM node, and reopen the saved set on a new node process on the same host. It also specifies what happens to changes made between saves.

### Success Criteria

The package works from its Hex contents. Existing callers can still use their modules through the import. The next design review has one lifecycle model with clear boundaries, failure behavior, and named product decisions.

### Scope Boundaries

Implementation scope covers `jido_workspace` source, tests, config, CI, and documentation. Phase one preserves the imported module names and behavioral contracts. Phase two delivers a design candidate. Deprecations, downstream changes, agent plugin work, lifecycle implementation, and release actions are outside this plan's execution boundary.

### Key Decisions

Keep the package name `jido_workspace`. Import first. Shape the public surface against the combined code after the import passes its checks.

### Rejected Alternatives

A wrapper that still installs Shell and VFS as separate dependencies would retain the three package release boundaries. A public API rewrite during import would make it hard to isolate packaging regressions from behavior changes.

### Dependencies

Use the three recorded source revisions and their existing runtime dependencies. Use the Workspace test-only Jido source pin for current Action and Signal contract tests. Run provider tests only with their required local fixtures or authorized environments.

### Outstanding Questions

The project owner will review save timing, what happens to unsaved edits, the first storage provider and recovery scope, asset deletion and retention, and the final public function names. These decisions govern lifecycle implementation. The import can proceed before that review.

### Sources

The direct request sets the package name, import boundary, and work order. The current file, command, and deployment contracts are in the [Workspace README](../../README.md), [Sandbox guide](../../SANDBOX.md), and [Deploy guide](../../DEPLOY.md).

## Planning Contract

### Product Contract Preservation

The plan records the direct request. Lifecycle details below are proposals for review.

### Current System

| Source | Import baseline | What it supplies |
| --- | --- | --- |
| Workspace | `b07e80692d61f2dbd74acf5b96755e92d7e10aca` | Workspace controller, policy, Sandbox, Deploy, and test-only Jido contracts |
| Shell | `3c585dd890376f16de5d38902ab7dd0124424a56` | Sessions, mount routing, commands, CLI, and execution backends |
| VFS | `e2d2922e64904294b31cc6bb93c205e1f5b695cc` | Storage adapters, revisions, and atomic InMemory captures |

The import uses the current local `main` revisions. The earlier one-package prototype built a local Hex tarball and passed a local smoke test. It used VFS `eba18f5`. The two VFS commits since that point only change development dependency locks.

`Jido.Workspace.open/1` starts an owner-monitored controller. It creates storage and starts the Shell session on demand. Cleanup stops the session, removes mounts, and stops process-backed storage. The default memory workspace disappears with its storage. `Jido.VFS.Capture` holds an immutable file tree. Its checked-edit token ties to live storage. The Deploy snapshot projects a subset of a capture into a deployment payload. A workspace can also use adapter-owned persistent files, but the current Workspace handle cannot serve as a durable asset reference. [Workspace facade](../../lib/jido_workspace.ex) · [Lifetime controller](../../lib/jido_workspace/lifetime.ex) · [Deploy snapshot](../../lib/jido_workspace/deploy/snapshot.ex)

### Target System

Phase one puts all modules behind one application startup. The existing Workspace calls keep their return types and policy. The build resolves its runtime dependencies from Hex and works without the source repositories.

Phase two proposes that `Jido.Workspace` become the main API. Its live handle owns access, mounted files, and execution sessions. A durable asset reference identifies saved content independently of any process. VFS and Shell remain accessible to direct callers during this work. The design review will decide which lower-level calls stay part of the supported surface.

### Key Technical Decisions

| ID | Decision and reason | Alternative and consequence | Governs |
| --- | --- | --- | --- |
| KTD1 | Import tracked source at exact commits and record its origin and license in Workspace. Keep the diff attributable. | Rewriting the modules during import would obscure regressions. Package-specific changes should be easy to review separately from imported code. | R1, R2 · U1 |
| KTD2 | Use one Mix manifest, release artifact, and application entry point. Start VFS support, Shell supervision, and Workspace services in dependency order. Keep registered names and message formats. | An umbrella with separate dependencies would leave storage and execution on separate release paths. One app requires changes to startup, version reporting, and packaging. | R1, R4 · U1–U3 |
| KTD3 | Design durable asset identity separately from process identity and live revision tokens. Start the design review with explicit saves of immutable content. | Auto-save and live disk worktrees can reduce the amount of unsaved work, but introduce recovery and concurrency rules for each write. Compare them during the review before selecting a public contract. | R3 · U4 |

### System Boundaries and Change Surface

| Surface | Planned change |
| --- | --- |
| Imports | Bring over production source, supported CLI tasks, adapter and backend tests, fixtures, and applicable notices. Use committed content. Update affected install tasks to select the combined package. |
| Build and runtime | Replace cross-package path and Git dependencies with the direct dependency set. Regenerate the Workspace lock. Resolve overrides through compatible constraints. Start the existing supervision trees under Workspace. Remove calls in the combined code to start the standalone OTP applications. Make Shell version reporting use the combined application version. |
| Config and docs | Audit old application config keys, including GitHub adapter config and Shell guardrails. Preserve their lookup behavior during import or document and test an equivalent migration in the combined package. Move the VFS compile-time README resource to a dedicated path and include it in the tarball. Update Workspace docs and contributor instructions to describe the actual API and app layout. |
| Tests and CI | Combine the three `test/test_helper.exs` roles. Preserve VFS fixture setup, Shell support, and Workspace integration isolation. Check shared test module names, tag collisions, test environments, format and lint settings, and packaging paths. Retain coverage for the imported surface. |
| Asset lifecycle design | Define save and reopen independently of runtime cleanup. Keep credentials, PIDs, mounts, and processes outside stored asset data. Keep a deployment payload conversion distinct from a general workspace save so it can preserve empty directories and other supported metadata. |

### Implementation Units

#### U1 — Import source and boot one application

- **Requirements** R1, R2, R4. **Dependencies** None.
- **Surfaces and direction** Import the source, fixtures, notices, and test material at the listed revisions. Update `mix.exs`, `mix.lock`, the application entry point, the Workspace startup call, Shell version lookup, and the VFS documentation resource. Keep runtime behavior and registered names. Review the optional Bash and Igniter paths with and without their dependencies. Preserve the current Jido tests through a test-only dependency.
- **Test scenarios and proof** Compile in a copy without sibling repositories. Start VFS, Shell, and Workspace from the combined application. Run the local smoke flow in the Verification Contract. Verify that each source repository has the same status and ref as at the start of execution.
- **Completion** The combined project boots and passes the smoke flow with a single application entry point.

#### U2 — Run the imported behavior suites

- **Requirements** R1, R4. **Dependencies** U1.
- **Surfaces and direction** Reconcile test helpers, provider probes and tags, test config, quality tasks, and coverage wiring. Preserve opt-in provider coverage and the isolated Workspace integration examples.
- **Test scenarios and proof** Pass the required local suites and quality gates. Exercise storage captures and stale edits, Shell session cleanup, Workspace owner exit, Sandbox execution, local Deploy examples, and the existing Jido Action and Signal contracts. Report which provider suites ran and why any were excluded.
- **Completion** Required local gates pass and each test exclusion has a known reason.

#### U3 — Prove a self-contained Hex package

- **Requirements** R1, R2, R4. **Dependencies** U2.
- **Surfaces and direction** Update package contents and installation docs. Use `mix hex.build`. Check the package metadata, unpack its `contents.tar.gz` into a temporary directory, and use that directory as a path dependency from a fresh Mix consumer. Use only files shipped in the tarball. Confirm that these include the VFS documentation resource and target-side Erlang deployment module. Check the dependency graph for separate Shell, VFS, or Jido core runtime dependencies.
- **Test scenarios and proof** Run the local smoke flow from the installed tarball with no sibling checkout. Confirm that startup, command execution, and cleanup work. Confirm the source repository refs and status again.
- **Completion** The installed package passes the smoke flow and the source repositories match their starting state.

#### U4 — Design a durable Workspace lifecycle

- **Requirements** R3. **Dependencies** U3.
- **Surfaces and direction** Produce a design candidate that starts at `Jido.Workspace` and traces the flows below against the combined code. Use durable storage independent of the runtime. Recommend the smallest first backend and document where the recommendation stops.
- **Test scenarios and proof** Walk through save, owner exit, node restart and reopen, and export of the exact saved assets. Walk through a process or node failure before and after save success, a competing writer, a partial restore, and an explicit deletion request. Document what each caller sees and which assets remain available.
- **Completion** The design candidate has one clear public workflow, covers each failure case, and names the decisions for owner review. It adds no lifecycle code.

**Lifecycle design starting point**

| User operation | Proposed contract for review |
| --- | --- |
| Open and work | A live handle mounts storage and opens execution resources as needed. Policy belongs to the live owner. |
| Save | Save an immutable file tree to a host-configured store. Return a portable reference only after the store commits the manifest and required content. Preserve file bytes, canonical paths, empty directories, and executable modes for supported captures. Use an expected revision for a mutable reference if the API offers one. |
| Close or lose the owner | Stop sessions and release live resources. A saved asset remains reachable. A failed save leaves the previous committed asset available. Specify loss of unsaved edits for the explicit-save design. |
| Reopen | Read and validate the saved asset into a fresh workspace with a new live revision. Give the caller a usable handle after restore and policy checks succeed. On failure, release partial live resources and keep the saved asset. |
| Hand off or retire | Export or project a fixed saved revision. Keep retention and physical deletion under an explicit host policy. Review the ownership and reference rules before adding delete or prune operations. |

Start the design with a local store and a single capturable root as a candidate. Define the storage failure model, atomic visibility, retry behavior, format version, and how to recognize a stale or missing reference. Decide whether frequently changed work needs automatic recovery before it is explicitly saved. Map Shell commands, Sandbox execution, and deployment into this model without assuming automatic file synchronization. Treat concurrent writers, command file views, and durable references as distinct contracts.

### Work Graph

U1 starts first. U2 requires the combined runtime. U3 verifies the integrated package from the tarball. U4 uses that package as the baseline for design. The critical path is `U1 → U2 → U3 → U4`. The owner reviews the result of U4 before any durability implementation.

### Verification Contract

Run Mix commands from `jido_workspace` in a stand-alone copy for package checks. Use a Git working tree if test dependencies need Git hooks. Record the Elixir and OTP versions, imported refs, and enabled provider suites. [Workspace Mix tasks](../../mix.exs)

| Gate | Covers | Pass signal |
| --- | --- | --- |
| Local smoke flow | R1 · U1, U3 | Open memory workspace, write and read, run virtual `cat`, capture and replace using a revision, run a local Sandbox command, then close and check cleanup. Repeat from the installed package. |
| Behavior and analysis | R1, R4 · U2 | `mix test`, `mix test.integration`, and `mix quality` pass. Run the four local VFS adapter integration suites explicitly. Verify existing integration tags still select the intended cases. Report provider suites by name when prerequisites such as MinIO, Docker, runsc, Sprite, or SSH are unavailable. |
| Package and scope | R1, R2, R4 · U1, U3 | `mix hex.build` succeeds. The tarball consumer resolves without sibling packages or Jido core. The recorded refs and worktree status for the two source repositories are identical before and after. |
| Lifecycle design review | R3 · U4 | Trace each lifecycle operation and failure case. Show what save success means, when asset visibility changes, and how a fresh runtime reopens it. Identify all remaining owner decisions. |

With a local Git fixture identity configured, run these imported VFS suites from `jido_workspace`:

```sh
mix test --include integration \
  test/jido_vfs/adapter/ets_integration_test.exs \
  test/jido_vfs/adapter/git_integration_test.exs \
  test/jido_vfs/adapter/in_memory_integration_test.exs \
  test/jido_vfs/adapter/local_integration_test.exs
```

### Rollout and Recovery

The package is unreleased. Verify it in an isolated consumer first. A later consumer that uses all three packages must remove the separate Shell and VFS dependencies in the same change that installs the combined package, because the packages define the same modules. If the consumer smoke test fails, return that consumer to its previous dependency graph. Consumer migration, publishing, and asset data migration require separate work.

### Risks and Assumptions

- Package independence adds the required Shell runtime dependencies to VFS-only consumers of the combined package.
- A passing build does not prove runtime compatibility. Compile-time resources, app config, optional backends, and test tags each need direct checks.
- The current capture API supports a single memory root. A first durable design that uses it must make this boundary visible and define the behavior for unsupported roots.
- A stored checkpoint proves recoverable content only within the stated storage failure model. Node restart, host or disk loss, and retention are separate requirements.

### Open Planning Decisions

For U4, the project owner reviews explicit save versus automatic recovery, checkpoint store and failure scope, deletion and retention, and the final public API. The executor can propose a default for each. Approval controls later lifecycle implementation. There is no outstanding decision that blocks U1.

### Definition of Done

One installable `jido_workspace` tarball contains the imported code and passes the local smoke, integration, and quality gates. Imported capabilities, test-only Jido integration, and provenance are accounted for. The source repositories match their starting state. The lifecycle proposal defines what survives runtime exit and how a caller can reopen or hand off saved assets, and it states what the owner must decide before implementation.

### Planning Sources

- [Workspace application](../../lib/jido_workspace/application.ex)
- [Workspace API and types](../../lib/jido_workspace.ex)
- [Shell import revision](https://github.com/agentjido/jido_shell/tree/3c585dd890376f16de5d38902ab7dd0124424a56)
- [VFS import revision](https://github.com/agentjido/jido_vfs/tree/e2d2922e64904294b31cc6bb93c205e1f5b695cc)

## Adapter Results

- This Markdown file is the canonical plan.
