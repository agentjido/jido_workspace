# Jido Workspace examples

The examples show how to use `jido_workspace`. Each runnable example has an
integration test for a result that the caller can observe.

Start with the [use-case matrix](table_of_contents.md#use-case-matrix). Each
row names a filesystem or storage role, an execution provider, a security
guarantee, and a lifecycle outcome. Choose combinations that test different
guarantees. Reuse a workflow across providers when the public contract is
the same.

## Start here

The [four core examples](00_core/README.md) use `Jido.Workspace` for files,
commands, access policy, and snapshots. The report workflow uses the same
calls on memory and Docker. The host selects the provider with a named
profile.

Create a project, move a draft into review, and list the result with the
same file calls on memory and Docker.
[Edit and list a project](01_working_files/01_01_edit_and_list_a_project/README.md)

Open a host-owned Git checkout with a named Docker profile. Edit a file
and close the handle. The host can inspect its changes with Git.
[Keep a host-owned checkout](01_working_files/01_02_keep_a_host_owned_checkout/README.md)

Read a draft and its revision. Apply an edit only while the file has the
same content. Use the same calls on memory and Docker.
[Apply an edit against a known revision](01_working_files/01_03_apply_an_edit_against_a_known_revision/README.md)

Search the project for literal text. Use the profile to select which paths
and content to search, then read the file you want to inspect.
[Find and inspect files](01_working_files/01_04_find_and_inspect_files/README.md)

Copy a file in chunks and verify its checksum. Stop the source during a
replacement and check that the previous file remains.
[Read and write large files](01_working_files/01_05_read_and_write_large_files/README.md)

The first lifecycle example uses the host supervision tree to own a
workspace and checks recovery of its saved report after the owner or
controller exits. [Open under supervision](05_lifecycle/05_01_open_under_supervision/README.md)

The next lifecycle example bounds the caller's wait while an accepted
command or save finishes. [Close while work is running](05_lifecycle/05_02_race_close_with_work/README.md)

An allocation can also outlast the caller. Retry from the saved snapshot
while Workspace releases the disposable tree. [Recover a late or failed allocation](05_lifecycle/05_03_recover_failed_open/README.md)

Check the workspace phase and match an active command to its result or
error event with the execution ID. [Inspect workspace and command state](05_lifecycle/05_04_inspect_state/README.md)

Give two owners separate trees and command limits, then close one
workspace while the other command continues. [Run concurrent workspaces](05_lifecycle/05_05_run_concurrent_workspaces/README.md)

Run a tool in a relative working directory and keep its bounded output
when it exits with an error. [Run a command with argv and cwd](02_commands/02_01_run_argv_and_cwd/README.md)

Read bytes while a command runs and detect gaps when an observer falls
behind. [Stream live output](02_commands/02_02_stream_live_output/README.md)

Run edits and commands in order. Check which step stopped the batch
and which files remain. [Run an ordered batch](02_commands/02_03_run_an_ordered_batch/README.md)

Request a command stop and wait for evidence before writing or saving.
[Stop or time out a command](02_commands/02_04_stop_or_time_out/README.md)

Send input to a running program and confirm cleanup when its client
disconnects. [Use an interactive session](02_commands/02_05_use_an_interactive_session/README.md)

Give editors, inspectors, and publishers distinct permissions. Check that
an inspector can run a command while the tree stays read-only.
[Authorize by operation](03_security_and_policy/03_01_authorize_by_operation/README.md)

Check relative paths on memory and Docker. Use a temporary checkout to
check symbolic links, hard links, and an outside fixture.
[Keep paths within the root](03_security_and_policy/03_02_keep_paths_within_the_root/README.md)

Limit command entry points on memory and Docker. Check that a confirmed
Docker start failure leaves the workspace available for edits and saves.
[Limit tools and dependencies](03_security_and_policy/03_03_limit_tools_and_dependencies/README.md)

Require disabled networking and confirm that a workspace command cannot
reach a live endpoint on a private Docker network.
[Control network access](03_security_and_policy/03_04_control_network_access/README.md)

Send a fixture credential to one approved Docker command through its
input pipe. Check output, diagnostics, and the saved tree.
[Scope credentials and diagnostics](03_security_and_policy/03_05_scope_credentials_and_diagnostics/README.md)

Bound command time and retained output on memory and Docker. Inspect
the Docker resource ceilings and require the ones the workload needs.
[Enforce execution limits](03_security_and_policy/03_06_enforce_execution_limits/README.md)

Run an approved host command in a disposable directory. Save the result
and close the workspace. Run the same command in a local Docker container.
[Run a disposable local sandbox](04_sandboxes_toolchains_and_services/04_01_run_a_disposable_local_sandbox/README.md)

Open the same report with different isolation profiles. Check host file
access and require the runtime the workload needs.
[Compare isolation profiles](04_sandboxes_toolchains_and_services/04_02_compare_isolation_profiles/README.md)

Run a trusted host tool with erlexec. Check that the process group is
gone before saving the tree.
[Supervise a native process](04_sandboxes_toolchains_and_services/04_03_supervise_a_native_process/README.md)

Generate a report with Python in an image pinned by digest. Save it on
Docker and read it after restore on memory.
[Use a pinned language toolchain](04_sandboxes_toolchains_and_services/04_04_use_a_pinned_language_toolchain/README.md)

Generate the same report in the BEAM with Lua. Check that a stopped or
failed evaluation leaves its staged files out of the tree.
[Evaluate an embedded runtime](04_sandboxes_toolchains_and_services/04_05_evaluate_an_embedded_runtime/README.md)

Connect to a workspace service on an approved loopback port. Inspect
readiness, reconnect, and confirm container cleanup before saving.
[Start and inspect a service](04_sandboxes_toolchains_and_services/04_06_start_and_inspect_a_service/README.md)

Run a Linux command with a named Apple Container profile. Confirm container
removal and reopen a saved report on memory.
[Run on Apple Container](04_sandboxes_toolchains_and_services/04_07_run_on_apple_container/README.md)

Add a host provider to a named profile. Run a command over its file
tree and confirm that a failed open releases its lease.
[Add a provider through public callbacks](06_providers_and_persistent_infrastructure/06_01_add_a_provider/README.md)

Open a session on a host-owned machine. Close and reopen the same
reference, or ask the host for a fresh machine with a separate tree.
[Reuse a persistent machine or request a fresh one](06_providers_and_persistent_infrastructure/06_02_reuse_or_request_a_machine/README.md)

Record a command reference before launch. Use a recovery profile to
inspect, wait for, or stop the command after losing the launch reply or
the Workspace BEAM.
[Recover an old command](06_providers_and_persistent_infrastructure/06_03_recover_an_old_command/README.md)

Revoke a lease at the provider and verify that its old commands have
stopped before opening a replacement. Check a stale BEAM and a provider
connection loss.
[Block a stale writer](06_providers_and_persistent_infrastructure/06_04_block_a_stale_writer/README.md)

Give a local provider console the writer slot. Stop its processes and
remove its access before a new Workspace saves the reviewed tree.
[Hand off to an external maintainer](06_providers_and_persistent_infrastructure/06_05_hand_off_to_an_external_maintainer/README.md)

Save a memory candidate to a directory store and review the exact saved
version. Keep the earlier snapshot usable if a later publication fails.
[Save a scratch tree to disk](07_keep_useful_results/07_01_save_a_scratch_tree_to_disk/README.md)

Publish one report from a saved tree to a local Git branch. Check the
expected branch head during publication to preserve newer work.
[Publish a reviewed Git result](07_keep_useful_results/07_02_publish_a_reviewed_git_result/README.md)

Store one approved file under its digest in a scoped S3 prefix. Retry an
interrupted upload with the same bytes.
[Store a selected artifact in S3](07_keep_useful_results/07_03_store_a_selected_artifact_in_s3/README.md)

Run a build and test while following live output. Give the saved reference
to a read-only reviewer after the tests pass.
[Build, test, review, and hand off](08_deployment_and_application_workflows/08_01_build_test_review_and_hand_off/README.md)

Deploy the saved version to a separate target after the live workspace changes.
Check the saved bytes, modes, and empty directories in the release.
[Deploy a saved tree](08_deployment_and_application_workflows/08_02_deploy_a_saved_tree/README.md)

Inspect a verification failure after activation. Recover from the operation that
blocked the target and verify the restored release.
[Verify and recover a deployment](08_deployment_and_application_workflows/08_03_verify_and_recover_a_deployment/README.md)

Upgrade and downgrade a saved OTP release with live state. Observe the new
runtime generation after a failed migration and recover explicitly.
[Upgrade an OTP release](08_deployment_and_application_workflows/08_04_upgrade_an_otp_release/README.md)

Use a fresh BEAM to wait for an existing job. Confirm safe writer handoff, then
save, review, and publish the report to a local Git branch.
[Resume a long-running job](08_deployment_and_application_workflows/08_05_resume_a_long_running_job/README.md)

The [numbered chapters](table_of_contents.md#numbered-chapters) cover
working files, commands and streams, security, sandboxes, OTP lifecycle,
persistent providers, and deployment. Put the day-to-day workflow and its
security and recovery rules first. Save useful in-memory results to a
directory store. Git and S3 are optional examples for workflows that need
source history or object storage.

## Save and reopen after a BEAM restart

From the repository root, make a directory that both BEAM instances can
access. Keep the same terminal for both sessions.

```sh
export WORKSPACE_EXAMPLE_DIR="$(mktemp -d)"
iex -S mix
```

Paste this host configuration into each IEx session. Both profiles use the
same store ID and directory. The Docker profile needs a local Docker engine
and an installed `alpine:3.20` image.

```elixir
alias Jido.Workspace

root = System.fetch_env!("WORKSPACE_EXAMPLE_DIR")
reference_path = Path.join(root, "report.snapshot.json")

Application.put_env(:jido_workspace, :stores, %{"reports" => Path.join(root, "snapshots")})

Application.put_env(:jido_workspace, :profiles, %{
  memory: %{provider: :memory, policy: :full_access, store: "reports"},
  docker: %{
    provider: :docker,
    policy: :full_access,
    store: "reports",
    image: "alpine:3.20",
    require: %{isolation: :container, network: :disabled}
  }
})
```

In the first session, write the report and save the tree. Workspace writes
the file data to `snapshots/`. Keep the reference as a JSON file.

```elixir
{:ok, workspace} = Workspace.open(profile: :memory)
:ok = Workspace.write(workspace, "report.txt", "Report for today\n")
{:ok, snapshot} = Workspace.save(workspace)
:ok = File.write(reference_path, Jason.encode!(snapshot))
:ok = Workspace.close(workspace)
```

Exit IEx. Start a new `iex -S mix` in the same terminal and paste the host
configuration again. Read the reference and open the saved tree.

```elixir
snapshot = reference_path |> File.read!() |> Jason.decode!()
{:ok, workspace} = Workspace.open(profile: :memory, from: snapshot)
{:ok, "Report for today\n"} = Workspace.read(workspace, "report.txt")
:ok = Workspace.close(workspace)
```

To reopen the same tree on Docker, use `profile: :docker` in the open call.
Keep both the JSON reference and the snapshot store for as long as you need
to reopen the tree. The test runs the save and restore in separate BEAM
instances. [Restart test](00_core/00_04_restore_in_a_fresh_beam/example_test.exs)

## Use an example to shape the API

1. State the task and the result a caller can observe.
2. Try the workflow with the current public API and the smallest local fixture
   that can prove it. Use the same application calls in a provider-backed run.
3. Record where the API fits and where the example stalls. Include the
   failing call or missing guarantee. Use that evidence to propose the smallest
   public API change that lets the workflow complete.
4. Keep the example and its integration test together. Test the normal path
   and the failure, recovery, or cleanup behavior the example teaches. Use
   explicit synchronization and bounded waits for process and provider tests.

Each supported example has a `README.md`, reader-facing Elixir source,
and a colocated `*_test.exs` file tagged `:integration`. Add a `demo.exs` when
a standalone run helps. The README should state the visible result, exact test
command, setup, and limits of the proof. Advanced examples should add an
**API Fit and Gaps** section for missing operations, unclear ownership, and
code that more than one caller must write. Put test fixtures beside their
example. Keep private process state and test support out of the reader-facing
workflow.

## Local and provider-backed tests

The default examples should run offline with real Workspace processes,
temporary directories, and deterministic inputs. Use a local provider fixture
to test how Workspace handles provider replies and failures. Verify actual
containment, resource cleanup, and remote recovery with the provider that makes
those guarantees.

Keep real Docker, remote machines, and other external infrastructure opt-in.
Document the runtime, configuration, credentials, possible costs, timeout,
and cleanup. Use resources dedicated to the test. In a persistence example,
check that the machine survives Workspace close before the test harness
releases its own fixture.

## Run the numbered examples

From the repository root, run the numbered examples.

```sh
mix test.examples --warnings-as-errors
```

To run all the container examples, use a local Docker engine with
`alpine:3.20` and the pinned Python image installed. The host installs
these test fixtures before running the examples.
[Install the Python image](04_sandboxes_toolchains_and_services/04_04_use_a_pinned_language_toolchain/README.md#install-the-image)

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test.examples --warnings-as-errors
```

To include the S3 tests, put the local MinIO executable on `PATH` and add
`--include s3` to the command. [Set up the MinIO fixture](07_keep_useful_results/07_03_store_a_selected_artifact_in_s3/README.md#run-the-integration-tests)

For a focused run, use the test command in the lesson README.
`mix test.integration` runs both the numbered examples and the existing
tests under `test/examples/`.
