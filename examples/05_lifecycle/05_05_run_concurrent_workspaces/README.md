# 05.05 Run concurrent workspaces

Give each owner a workspace and a named profile. Each workspace has its
own tree and command slot. Closing one workspace releases its resources
while another workspace can continue its work.

## Set the limits in the profiles

```elixir
report = %{provider: :memory, policy: :full_access, store: "reports"}

config :jido_workspace,
  profiles: %{
    short_report: Map.put(report, :limits, %{timeout_ms: 5_000, output_limit: 5}),
    wide_report: Map.put(report, :limits, %{timeout_ms: 10_000, output_limit: 8})
  }
```

Set `output_limit` in bytes and `timeout_ms` in milliseconds. Each cap
applies to one command. Workspace uses the lower value from the profile
and the run options. A caller can use a lower limit for a single command.
Use a [configured snapshot store](../../README.md#save-and-reopen-after-a-beam-restart)
to keep both results after close.

## Run two reports

Use two host-supervised owners. The report reads run in caller tasks.
[Owner supervision](../05_01_open_under_supervision/README.md) ·
[Report task](example.ex)

```elixir
alias Jido.Workspace
alias Jido.Workspace.Examples.ConcurrentReports

{:ok, first} = Workspace.open(profile: :short_report, owner: first_owner)
{:ok, second} = Workspace.open(profile: :wide_report, owner: second_owner)
:ok = Workspace.write(first, "report.txt", "alpha-message")
:ok = Workspace.write(second, "report.txt", "beta-message")

first_read = ConcurrentReports.read(first)
second_read = ConcurrentReports.read(second)

{:ok, %{output: "alpha", truncated: true}} = Task.await(first_read, 15_000)
{:ok, first_snapshot} = Workspace.save(first)
:ok = Workspace.close(first)

{:ok, %{output: "beta-mes", truncated: true}} = Task.await(second_read, 15_000)
{:ok, second_snapshot} = Workspace.save(second)
:ok = Workspace.close(second)
```

The same caller code works with Docker profiles. Set the base profile
to `provider: :docker`, supply a local image, and require container
isolation and a disabled network.
[Docker profile](../../README.md#save-and-reopen-after-a-beam-restart)

## Run the tests

```sh
mix test examples/05_lifecycle/05_05_run_concurrent_workspaces/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/05_lifecycle/05_05_run_concurrent_workspaces/example_test.exs --include integration
```

The tests hold both commands until they run at the same time. The memory
tests hold the tree processes. The Docker tests use a pipe in each live
container. The tests check that the first close releases its resources,
that the second command and a later write succeed, and that the two
snapshots reopen with their own contents. They also test upper limits
from the profile, lower limits from the caller, and invalid settings.
[Tests](example_test.exs)

## API fit and gaps

The host sets the limits at open. The provider can take additional time
to confirm cleanup after the execution timeout. The memory deadline test
blocks a worker outside a tool checkpoint and checks the write fence with
`:quiescence_unknown`. The Docker deadline
test confirms the command stopped and verifies that the tree can be
saved. These checks cover command time and returned bytes.
For Docker resource ceilings, see
[03.06 Enforce execution limits](../../03_security_and_policy/03_06_enforce_execution_limits/README.md).
