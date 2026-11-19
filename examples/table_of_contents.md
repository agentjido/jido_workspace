# Workspace example table of contents

**Status** Chapter 00 has runnable examples. The matrix and chapters 01
through 08 describe the target coverage.

## Use-case matrix

Each row is a workflow with a specific result and failure to test. A profile
binds the file tree to a runner and declares the required permissions and
runtime controls. A workflow can also import inputs or save outputs in a
separate store.

| Use case | Filesystem and storage role | Execution provider | Security to prove | Lifecycle to prove |
| --- | --- | --- | --- | --- |
| **Core · Scratch work** | Memory is the live tree. A store holds the saved result. | Virtual tools | Paths stay under the root. Tools use the same tree as file calls. | Open, edit, run, save, close, and restore. An old handle loses access. |
| **Core · Isolated build** | A Workspace-owned local directory is the live tree. | Isolated native runtime | Literal argv and relative working directory work. A command cannot read a test fixture outside the allowed root. | Repeat the scratch workflow. A timeout leaves the tree blocked for writes and saves until the provider confirms that its writers stopped. Close cleans up disposable resources. |
| **Core · Restricted access** | Use a prepared memory tree and repeat on the isolated directory. | Virtual tools and isolated native runtime | Permit reads. Refuse writes through file calls and commands that could write. Refuse a profile when the provider lacks a required control. | Failed admission leaves no usable handle or allocated resource. |
| **Core · Restore after restart** | Save a portable tree to a host-configured directory store. | Save on memory. Reopen on memory or Docker. | Check the reference and content before returning a handle. | Refuse save while a writer is active. A fresh BEAM restores the saved tree. A failed publication leaves the previous reference usable. |
| Day-to-day editing | Memory or a host-owned checkout | Virtual tools or trusted local runner | Confine file calls to the root and check stale edits. | Close preserves a host-owned directory. |
| Long command or script | One live tree | Virtual or native tools | Bound output, run time, and work admitted by the profile. | Stream output, stop on failure, and account for partial effects and child processes. |
| Run an untrusted tool | Owned sandbox tree | Isolated native runtime | Verify file, network, secret, and resource restrictions with test fixtures. | Refuse an unsupported profile. Confirm cleanup after a crash or timeout. |
| Run a toolchain or service | Owned tree and runtime-scoped files | Pinned runtime or sandbox service | Expose only the required toolchain, environment, and ports. | Check readiness, reconnect to the service, then stop it and confirm cleanup. |
| Add a provider | Provider-bound tree | Host-supplied provider | Report enforceable controls. Make unsupported requests visible. | Handle partial allocation, late replies, and repeated release. |
| Resume work on a persistent machine | Provider-owned disk | Remote runtime | Keep write access blocked until prior writers are ruled out. | Reuse or request a machine. Recover a command after a lost reply or BEAM loss. |
| Keep the result of a scratch session | Memory to a directory store. Git is an optional reviewed output. | Virtual or native tools before save | Verify saved content and store access. | Keep a result after close. Restore it later or hand it to another process. |
| Use an object store when needed | S3-backed input or saved output | Existing workspace runner | Scope access to a prefix and keep store credentials with the host. | Confirm which result a reader sees after an interrupted upload. |
| Deploy a checked result | Immutable saved tree and separate target | Native toolchain and Deploy target | Limit target access and verify the input identity. | Observe activation, verification, and recovery. |

The related guides and tests cover storage adapters, Docker isolation, and
deployment. [VFS adapter guide](../docs/vfs/README.md) · [Docker tests](../test/examples/docker_sandbox_test.exs) · [Deploy guide](../DEPLOY.md)

## First examples

These examples use the public Workspace API. [Core chapter](00_core/README.md)

| Example | What the test checks today |
| --- | --- |
| [00.01 Work on one tree](00_core/00_01_work_on_one_tree/README.md) | File calls and virtual tools share a memory tree. A closed handle refuses reads. |
| [00.02 Repeat the workflow on Docker](00_core/00_02_repeat_on_an_isolated_provider/README.md) | One report function runs on memory and Docker with literal arguments and a relative working directory. |
| [00.03 Enforce a restricted profile](00_core/00_03_enforce_a_restricted_profile/README.md) | Both providers enforce read-only access. Open refuses invalid profiles and unmet requirements. A Docker command cannot read the host fixture. |
| [00.04 Restore in a fresh BEAM](00_core/00_04_restore_in_a_fresh_beam/README.md) | Save the tree and persist a JSON reference. Reopen on memory or Docker in a new BEAM. Verify bytes, an empty directory, and the earlier snapshot after damage to a later save. |

## Aspirational chapters

Each numbered item is a proposed example with a colocated integration test.
The chapter numbers give a reading order. Chapter 00 is the first milestone.

### 01 Working files

- **01.01 Edit and list a project** — Create, read, list, move, and remove entries. Check the result for a missing path.
- **01.02 Keep a host-owned checkout** — Open an existing directory, edit it, and verify that close preserves it.
- **01.03 Apply an edit against a known revision** — Reject a stale write after another caller changes the file.
- **01.04 Find and inspect files** — Search a project and check which hidden, binary, and generated entries the profile includes.
- **01.05 Read and write large files** — Transfer data in chunks and check what an interrupted write leaves behind.

### 02 Commands, streams, and scripts

- **02.01 Run a command with argv and cwd** — Pass literal arguments and inspect a nonzero exit.
- **02.02 Stream live output** — Observe bytes before exit and report gaps to a slow observer.
- **02.03 Run an ordered batch** — Apply edits and commands from a list. Check partial effects and the exact step that stopped the batch.
- **02.04 Stop or time out a command** — Keep bounded partial output and confirm whether the command and its children stopped writing.
- **02.05 Use an interactive session** — Explore input, output, cancellation, and terminal disconnect. A PTY is a candidate capability.

### 03 Security and policy

- **03.01 Authorize by operation** — Compare read, edit, execute, and save permissions on the same tree.
- **03.02 Keep paths within the root** — Test relative paths and links with a fixture outside the approved tree.
- **03.03 Limit tools and dependencies** — Allow the approved command set and test the result when a required tool is absent.
- **03.04 Control network access** — Verify that a network-disabled profile cannot reach a test endpoint.
- **03.05 Scope credentials and diagnostics** — Pass a fixture secret only to the approved program. Check output, errors, events, and saved files for unintended exposure.
- **03.06 Enforce execution limits** — Test time, output, and applicable process, memory, and disk limits. Check that the provider reports which limits it enforces.

### 04 Sandboxes, toolchains, and services

- **04.01 Run a disposable local sandbox** — Use native commands in an owned root. Confirm cleanup through the public API.
- **04.02 Compare isolation profiles** — Exercise the same workload in available sandbox runtimes. Reject a required runtime when it is unavailable.
- **04.03 Supervise a native process** — Test short-lived output and child process cleanup. Evaluate the preferred native runner, erlexec, behind the provider.
- **04.04 Use a pinned language toolchain** — Run Python or Node in the working directory and read a file the program produced.
- **04.05 Evaluate an embedded runtime** — Compare working-directory access, interruption, and isolation with the native toolchain example. This is exploratory.
- **04.06 Start and inspect a service** — Check readiness, use an approved port, reconnect, stop the service, and confirm cleanup.

### 05 OTP lifecycle and observability

- **05.01 Open under supervision** — End the owner or controller and confirm handle expiry and resource cleanup.
- **05.02 Race close with a command or save** — Check which work can finish, what close returns, and when another writer can enter.
- **05.03 Recover a late or failed allocation** — Exercise a partially created resource and retry release.
- **05.04 Inspect workspace and command state** — Correlate status, output, and failure events using public calls. Check diagnostic access separately from write access.
- **05.05 Run concurrent workspaces** — Use distinct roots and limits for two owners. Confirm that closing one leaves the other usable.

### 06 Providers and persistent infrastructure

- **06.01 Add a provider through public callbacks** — Bind one root and runner, report enforced capabilities, and prove cleanup on failure.
- **06.02 Reuse a persistent machine or request a fresh one** — Check resource identity and files after session close.
- **06.03 Recover an old command** — Find the command after BEAM loss or a lost launch reply. Inspect, wait for, or stop it.
- **06.04 Block a stale writer** — Require proof that the old session cannot start writes and its commands cannot still write. Check the outcome when the provider is unreachable.
- **06.05 Hand off to an external maintainer** — Explore how an SSH session or provider console can take ownership, then return it safely.

### 07 Keep useful results

- **07.01 Save a scratch tree to disk** — Keep a reviewed result after closing the memory workspace. Restore it from the saved reference.
- **07.02 Publish a reviewed Git result** — Explore an explicit commit or patch from a memory session when the host needs source history.
- **07.03 Store a selected artifact in S3** — Check scoped upload, retry, and retrieval when a consumer needs object storage.

### 08 Deployment and application workflows

- **08.01 Build, test, review, and hand off** — Run a complete tool loop with live output. Keep a saved version that another process can inspect.
- **08.02 Deploy a saved tree** — Change the live source and verify the target receives the exact saved version.
- **08.03 Verify and recover a deployment** — Force verification to fail and exercise explicit recovery.
- **08.04 Upgrade an OTP release** — Observe state across an upgrade and exercise a failed migration or downgrade.
- **08.05 Resume a long-running job** — Reattach to the machine, inspect the surviving work, and publish the verified result after write access is safe.
