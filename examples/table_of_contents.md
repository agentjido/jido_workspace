# Workspace example table of contents

**Status** All numbered examples in chapters 00 through 08 are runnable.

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
| **Core · Restore after restart** | Save a portable tree to a host-configured directory store. | Save on memory. Reopen on memory or Docker. | Check the reference and content before returning a handle. | Refuse save while a writer is active. A fresh BEAM restores the saved tree. Damage to a later bundle leaves the earlier reference usable. |
| Day-to-day editing | Memory, a disposable directory, or a host-owned checkout | Virtual tools or Docker | Confine file calls to the root and check stale edits. | Close preserves a host-owned directory. A surviving Docker writer blocks reopen. |
| Long command or script | One live tree | Virtual or native tools | Bound output, run time, and work admitted by the profile. | Stream output, stop on failure, and account for partial effects and child processes. |
| Supervise a trusted host tool | Disposable directory and snapshot store | Local with erlexec | Require a private process group. The tool has host file and network access. | Check that the group is gone before save. If a writer survives, fence the tree and preserve it during cleanup. |
| Run an untrusted tool | Owned sandbox tree | Isolated native runtime | Verify file, network, secret, and resource restrictions with test fixtures. | Refuse an unsupported profile. Confirm cleanup after a crash or timeout. |
| Run a pinned language toolchain | Disposable directory and snapshot store | Docker with a Python image digest | Check the image ID and network mode. Refuse an unavailable image at open. | Write a report in the command's working directory. Save it, close Docker, and restore it on memory. |
| Run an embedded script | Memory tree and snapshot store | Lua in the BEAM | Scope file calls to the working directory. Refuse host I/O and parent traversal. | Publish staged files together after success. Discard them if evaluation fails or stops. |
| Run a service | Owned tree and snapshot store | Docker command and loopback connector | Allow only profile-approved ports. Check disabled container networking and no host port bindings. | Check readiness, reconnect, stop the service, then save and restore the report. |
| Add a provider | Provider-bound tree and portable capture | Host-supplied callback module | Check enforced tree access and required isolation. Refuse unsupported requests. | Revoke by lease ID on partial allocation, late provision, or controller loss. Confirm release on retry. |
| Reuse or request a persistent machine | Dedicated working tree and durable infrastructure reference | Host-owned local Docker machine | Verify resource identity and refuse a second lease. | Keep the same machine and files after close. Open a fresh tree on a separate machine. |
| Recover a command on a persistent machine | Dedicated tree and durable command reference | Host service and local Docker job | Require the recovery grant without granting a lease. Refuse a duplicate launch and fence writes after an unknown result. | Inspect, wait for, or stop a command after a lost reply or Workspace BEAM loss. |
| Replace a writer | Dedicated tree and portable snapshot | Host service and local Docker job | Refuse stale file, launch, and capture requests. | Revoke the old lease and confirm its writers stopped before admitting a replacement. Keep the lease through connection loss. |
| Hand off to an external maintainer | Dedicated tree and portable snapshot | Host service and local Docker console | Use one writer slot. Refuse new console commands during return and confirm exit and removal. | Save from a replacement Workspace and restore the maintainer's review on memory. |
| Keep the result of a scratch session | Memory to a directory store | Memory or Docker for review | Review the exact saved tree and check store permissions. | Keep the earlier result after a failed publication and retry the new save. |
| Publish a reviewed report | Saved tree to a dedicated local Git branch | Memory or Docker for review, then host Git | Copy only the approved file as exact bytes. | Prepare a commit and update the branch only if its head still matches. Keep the newer head if publication is stale. |
| Store a selected artifact in S3 | Saved tree to a digest key in an S3 bucket | Memory or Docker for review, then host S3 client | Keep credentials with the host. Check that the store denies access outside the allowed prefix. | Interrupt a PUT and lose a completed PUT reply. Retry with the same bytes and keep the earlier artifact readable. |
| Build, test, and hand off | One working tree and a saved reference | Embedded Lua on memory or a native tool on Docker | Grant the reviewer import and read permissions. Refuse writes and saves from the review handle. | Follow live output, save only after both stages pass, and let a separate process reopen the checked tree. |
| Deploy a checked result | Immutable saved tree and separate target | Native toolchain and Deploy target | Limit target access and verify the input identity. | Observe activation, verification, and recovery. |
| Upgrade a running OTP release | Saved release trees and a separate target | Local BEAM control channel | Check target capability, immutable file bytes, and executable modes before release registration. | Migrate live state through upgrade and downgrade. Reconnect and recover after a failed migration. |
| Finish a job after client loss | Retained machine tree, portable snapshot, and local Git branch | Host-owned Docker job and memory review | Confirm command success and a settled lease. Verify saved report bytes before the branch update. | Resume observation in a fresh BEAM. Reattach for safe save, review, and publication. |

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

## Numbered chapters

The chapter numbers give a reading order. Links to example READMEs mark
implemented items with colocated integration tests.

### 01 Working files

- [**01.01 Edit and list a project**](01_working_files/01_01_edit_and_list_a_project/README.md) — Create, read, list, move, and remove entries on memory and Docker. Check missing paths and preserve the entries when a move finds an occupied destination.
- [**01.02 Keep a host-owned checkout**](01_working_files/01_02_keep_a_host_owned_checkout/README.md) — Edit an existing Git checkout on Docker. Confirm close and owner exit preserve the tree. When a controller dies with a writer still running, reopen waits for host recovery.
- [**01.03 Apply an edit against a known revision**](01_working_files/01_03_apply_an_edit_against_a_known_revision/README.md) — Two callers read one revision on memory and Docker. One edit wins and the other returns `:stale_revision`. A command can also make a revision stale.
- [**01.04 Find and inspect files**](01_working_files/01_04_find_and_inspect_files/README.md) — Search literal content on memory and Docker. Check hidden paths, binary content, generated directories, links, and scan limits.
- [**01.05 Read and write large files**](01_working_files/01_05_read_and_write_large_files/README.md) — Copy and verify a large file in chunks on memory and Docker. A failed source or caller exit leaves the previous file in place.

### 02 Commands, streams, and scripts

- [**02.01 Run a command with argv and cwd**](02_commands/02_01_run_argv_and_cwd/README.md) — Pass literal arguments in a relative directory and keep bounded partial output on a nonzero exit. Check invalid working directories on memory and Docker.
- [**02.02 Stream live output**](02_commands/02_02_stream_live_output/README.md) — Read bytes before exit on memory and Docker. Check independent offsets, gaps, and the final bytes.
- [**02.03 Run an ordered batch**](02_commands/02_03_run_an_ordered_batch/README.md) — Apply edits and commands from a list. Check partial effects, output limits, and the exact step that stopped the batch.
- [**02.04 Stop or time out a command**](02_commands/02_04_stop_or_time_out/README.md) — Cancel by execution ID, keep bounded output after confirmed stop, and check the write fence when a worker or provider cannot confirm it.
- [**02.05 Use an interactive session**](02_commands/02_05_use_an_interactive_session/README.md) — Send input over a pipe, read the prompt and reply, and confirm Docker cleanup on cancellation or client disconnect.

### 03 Security and policy

- [**03.01 Authorize by operation**](03_security_and_policy/03_01_authorize_by_operation/README.md) — Compare read, edit, execute, import, and save grants on memory and Docker. Run read-only commands and check that the tree stays unchanged.
- [**03.02 Keep paths within the root**](03_security_and_policy/03_02_keep_paths_within_the_root/README.md) — Check relative paths on memory and Docker. Refuse symbolic link traversal in a Docker checkout, and preserve the outside hard link when replacing the named entry.
- [**03.03 Limit tools and dependencies**](03_security_and_policy/03_03_limit_tools_and_dependencies/README.md) — Limit command entry points on memory and Docker. Check an unsupported virtual tool, a missing native executable, and the write fence when removal fails.
- [**03.04 Control network access**](03_security_and_policy/03_04_control_network_access/README.md) — Check the network requirement in memory and use a reachable private Docker endpoint to prove that a workspace command stays isolated.
- [**03.05 Scope credentials and diagnostics**](03_security_and_policy/03_05_scope_credentials_and_diagnostics/README.md) — Pass a fixture credential to one Docker command. Check its output, errors, events, formatted OTP status, and saved tree. Memory refuses a required input pipe.
- [**03.06 Enforce execution limits**](03_security_and_policy/03_06_enforce_execution_limits/README.md) — Bound time and output on memory and Docker. Check Docker cgroup limits and the temporary disk cap. Refuse an unmet runtime ceiling at open.

### 04 Sandboxes, toolchains, and services

- [**04.01 Run a disposable local sandbox**](04_sandboxes_toolchains_and_services/04_01_run_a_disposable_local_sandbox/README.md) — Run an approved native command on Local and Docker. Save the result, remove the owned root at close, and check the direct Local child exits on timeout.
- [**04.02 Compare isolation profiles**](04_sandboxes_toolchains_and_services/04_02_compare_isolation_profiles/README.md) — Read one saved report across available providers. Check access to an outside fixture, the runtime used, and refusal without fallback.
- [**04.03 Supervise a native process**](04_sandboxes_toolchains_and_services/04_03_supervise_a_native_process/README.md) — Select erlexec in a Local profile. Capture fast output and confirm child cleanup before save. A surviving child keeps writes and saves blocked.
- [**04.04 Use a pinned language toolchain**](04_sandboxes_toolchains_and_services/04_04_use_a_pinned_language_toolchain/README.md) — Run Python from a pinned image in the workspace directory. Save the report and restore it on memory. Refuse an unavailable digest at open.
- [**04.05 Evaluate an embedded runtime**](04_sandboxes_toolchains_and_services/04_05_evaluate_an_embedded_runtime/README.md) — Generate the same report with Lua on memory. Check mediated file access and discard staged writes when a script fails or stops. Compare the result with Docker Python.
- [**04.06 Start and inspect a service**](04_sandboxes_toolchains_and_services/04_06_start_and_inspect_a_service/README.md) — Check readiness and reconnect through an approved Docker loopback port. Refuse other ports and confirm container removal on cancel and close.
- [**04.07 Run on Apple Container**](04_sandboxes_toolchains_and_services/04_07_run_on_apple_container/README.md) — Copy a file with literal arguments on Apple silicon. Reopen the snapshot on memory. Confirm removal after cancellation.

### 05 OTP lifecycle and observability

- [**05.01 Open under supervision**](05_lifecycle/05_01_open_under_supervision/README.md) — End the owner or kill the controller. Check handle expiry, memory release, Docker container and directory cleanup, and recovery from the last snapshot.
- [**05.02 Race close with a command or save**](05_lifecycle/05_02_race_close_with_work/README.md) — Let admitted work finish, fence new work, and use a bounded close wait with an explicit cleanup result.
- [**05.03 Recover a late or failed allocation**](05_lifecycle/05_03_recover_failed_open/README.md) — Bound the open wait, release a late memory or Docker allocation, retry removal of a partially created root, and reopen the saved tree.
- [**05.04 Inspect workspace and command state**](05_lifecycle/05_04_inspect_state/README.md) — Match the active execution ID to bounded output and outcome events on memory and Docker. Inspect a read-only or fenced workspace.
- [**05.05 Run concurrent workspaces**](05_lifecycle/05_05_run_concurrent_workspaces/README.md) — Test overlapping commands with separate roots and profile limits. Close one while the other command runs and reopen both saved trees.

### 06 Providers and persistent infrastructure

- [**06.01 Add a provider through public callbacks**](06_providers_and_persistent_infrastructure/06_01_add_a_provider/README.md) — Bind one tree and runner. Report effective capabilities. Check revocation before a late allocation and confirm cleanup after controller loss.
- [**06.02 Reuse a persistent machine or request a fresh one**](06_providers_and_persistent_infrastructure/06_02_reuse_or_request_a_machine/README.md) — Verify the same live container and files after close. Request a separate tree and refuse a stopped machine until the host restarts it.
- [**06.03 Recover an old command**](06_providers_and_persistent_infrastructure/06_03_recover_an_old_command/README.md) — Use the saved reference after a lost reply or BEAM loss. Inspect, wait for, or stop the Docker job while keeping the machine.
- [**06.04 Block a stale writer**](06_providers_and_persistent_infrastructure/06_04_block_a_stale_writer/README.md) — Revoke the old lease, verify its Docker job stopped, and refuse stale requests even after replacement. Check real connection loss, then save and restore on memory.
- [**06.05 Hand off to an external maintainer**](06_providers_and_persistent_infrastructure/06_05_hand_off_to_an_external_maintainer/README.md) — Give an external Docker console the writer slot. Check that detached writers block return and that the replacement can save the review.

### 07 Keep useful results

- [**07.01 Save a scratch tree to disk**](07_keep_useful_results/07_01_save_a_scratch_tree_to_disk/README.md) — Review a saved memory tree after close. Check store scope, fail publication, and retry while the earlier reference stays readable.
- [**07.02 Publish a reviewed Git result**](07_keep_useful_results/07_02_publish_a_reviewed_git_result/README.md) — Read the approved report from a saved tree on memory or Docker. Publish its exact bytes to a local Git branch and refuse a stale update.
- [**07.03 Store a selected artifact in S3**](07_keep_useful_results/07_03_store_a_selected_artifact_in_s3/README.md) — Upload one file from a saved tree to a scoped bucket prefix. Check what a reader sees after an interrupted PUT or a lost reply, then retry.

### 08 Deployment and application workflows

- [**08.01 Build, test, review, and hand off**](08_deployment_and_application_workflows/08_01_build_test_review_and_hand_off/README.md) — Follow build and test output by execution ID. Refuse to publish a failed test, then reopen the checked tree in a separate read-only process.
- [**08.02 Deploy a saved tree**](08_deployment_and_application_workflows/08_02_deploy_a_saved_tree/README.md) — Deploy a saved reference after the live tree changes. Check the saved bytes, executable modes, and empty directories on local and Docker targets.
- [**08.03 Verify and recover a deployment**](08_deployment_and_application_workflows/08_03_verify_and_recover_a_deployment/README.md) — Fail verification after activation on local and Docker targets. Inspect the blocking operation and verify explicit recovery from the approved snapshot.
- [**08.04 Upgrade an OTP release**](08_deployment_and_application_workflows/08_04_upgrade_an_otp_release/README.md) — Deploy saved releases, check state through upgrade and downgrade, and recover after a failed migration restarts the local BEAM. Check Docker's target capability refusal.
- [**08.05 Resume a long-running job**](08_deployment_and_application_workflows/08_05_resume_a_long_running_job/README.md) — Wait for the original Docker job from a fresh BEAM. Retire the old lease, reopen and verify the saved report on memory, then publish it to a local Git branch.
