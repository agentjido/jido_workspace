# 08.05 Resume a long-running job

Recover progress after the Workspace BEAM stops. Wait for the original job to finish, have the host retire the old lease, and give a new writer access to the same tree. Save the result, reopen it for review, and publish the verified report to a dedicated local Git branch.

## Run the full example

Run from the repository root with a local Docker engine, a locally available Alpine image, and Git. The test starts a host service and two Workspace BEAMs. It uses a separate machine, bundle store, and Git repository for each test.

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/08_deployment_and_application_workflows/08_05_resume_a_long_running_job/example_test.exs \
  --include integration
```

## Keep the command reference

The host selects the machine and configures the profiles on both BEAMs. The `:run` profile can open a writer for the machine. The `:recovery` profile has the `:recover` grant. The `:review` profile opens a saved tree on memory with read-only access to the same bundle store.

Persist the command reference before launch. Keep it outside the working tree. The app can then read it from a fresh BEAM even if the launch call returns no reply.

```elixir
alias Jido.Workspace
alias Jido.Workspace.CommandRef

command_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
{:ok, command} = CommandRef.new(machine, command_id)
:ok = File.write(command_path, Jason.encode!(command))
{:ok, workspace} = Workspace.open(profile: :run, infrastructure: machine)
Workspace.run(workspace, ["write-report"], command: command)
```

## Wait and take back write access

In the replacement BEAM, load the saved reference and inspect it. A bounded wait can return `:running`. Wait again for the same reference. In the test, the host signals the fixture to finish after it observes that the job is still running.

```elixir
reference = command_path |> File.read!() |> Jason.decode!()
Workspace.recover_command(:recovery, reference, :inspect)
Workspace.recover_command(:recovery, reference, :wait, timeout_ms: 5_000)
```

Wait for `%{status: :exited, exit_status: 0}` before publication. Then the host must revoke the old lease and confirm that all work admitted under it has stopped. In the fixture, `RecoveryHost.revoke_writer/3` does these checks for the specific machine and old lease. The provider keeps the old claim if it cannot confirm that those writers stopped. A replacement open must still pass provider admission.

## Publish the verified report

Use the report's workspace-relative path from the job's setup. Configure the bare repository and reviewed branch as in [07.02 Publish a reviewed Git result](../../07_keep_useful_results/07_02_publish_a_reviewed_git_result/README.md). Use the full branch head that the host accepted for this publication.

```elixir
Code.require_file("examples/08_deployment_and_application_workflows/08_05_resume_a_long_running_job/example.ex")
alias Jido.Workspace.Examples.ResumeJob

{:ok, %{snapshot: snapshot, commit: commit}} =
  ResumeJob.publish(reference, report_path, repo, expected_head)
```

The helper checks the command outcome and opens the replacement writer. It saves and closes that workspace, reopens the snapshot on a read-only profile, and checks the report bytes there. The Git publication compares the expected branch head before it updates the branch. Keep the snapshot reference to review the full tree and the commit ID to find the published report.

## API fit and limits

`Workspace.recover_command/4` reports a command outcome. The host owns the lease and decides whether to wait or stop the job. `Workspace.open/1`, `save/1`, and `close/1` handle the replacement session. The caller supplies the result check and the publication target.

The tests halt the first BEAM, rename its Docker job, and recover by the original command reference. They confirm that a running job and a retained lease each block publication, that invalid report bytes leave the branch unchanged, and that a stopped job cannot publish even when a complete-looking report exists. The verified report comes from the exact saved tree. The machine retains the same container ID and start time.

This proves recovery after Workspace BEAM loss while the host service and local Docker engine stay available. The fixture retains provider records in the host service. Its job runs in a separate container with the same working tree mount. Memory is used for review of the saved tree.

[Publication helper](example.ex) · [Integration tests](example_test.exs)
