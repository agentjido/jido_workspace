# 03.06 Enforce execution limits

Set command limits in a host profile. A caller can ask for less time
or fewer output bytes. Workspace uses the lower value. Use
`require.runtime_limits` when the provider must enforce an additional
resource ceiling.

```elixir
config :jido_workspace,
  profiles: %{
    report: %{
      provider: :docker,
      image: "alpine:3.20",
      policy: [:read, :write, :execute],
      limits: %{timeout_ms: 5_000, output_limit: 128},
      require: %{
        isolation: :container,
        network: :disabled,
        runtime_limits: %{memory_bytes: 268_435_456, pids: 256}
      }
    }
  }
```

Open the named profile and inspect the command and provider limits.
The provider must report a value at or below each requested runtime
ceiling. A missing limit or a higher value gives
`:unsupported_capability` at open.

```elixir
alias Jido.Workspace

{:ok, workspace} = Workspace.open(profile: :report)
{:ok, info} = Workspace.info(workspace)

%{timeout_ms: 5_000, output_limit: 128} = info.command_limits
%{memory_bytes: 268_435_456, pids: 256} = info.capabilities.runtime_limits

:ok = Workspace.write(workspace, "report.txt", "Quarterly report\n")
{:ok, %{exit_status: 0, output: "Quarterly", truncated: true}} =
  Workspace.run(workspace, ["cat", "report.txt"], output_limit: 9)

:ok = Workspace.close(workspace)
```

## Read the guarantees

| Limit | Memory | Docker with runc |
| --- | --- | --- |
| Command time and retained output | The controller applies the command ceilings. A virtual tool observes timeout at a checkpoint. | The controller applies the same command ceilings. The provider stops the container on timeout. |
| CPU, memory, and task count | `runtime_limits` is an empty map. | With the applicable engine support, the container has a one-CPU quota, a 256 MiB RAM limit, and a 256-task limit. The task count includes threads. |
| Temporary storage | The file tree lives in the BEAM. | `/tmp` has a 64 MiB limit per command. The container's image filesystem is read-only. |
| Workspace tree storage | The host controls the BEAM and snapshot store. | The host filesystem controls the `/workspace` bind mount and its available space. |

Docker's RAM cap allows swap according to the engine configuration. The
`tmp_bytes` value applies to `/tmp` only. It gives no quota for the working
tree or snapshot store. Memory and gVisor report no runtime ceilings through
this API. [Docker resource constraints](https://docs.docker.com/engine/containers/resource_constraints/) ·
[Docker temporary mounts](https://docs.docker.com/engine/storage/tmpfs)

A timed-out command can take additional time to stop. Save stays blocked
while the command can still write. A confirmed stop returns
`:timed_out` as the execution status. If the provider cannot confirm the
stop, Workspace returns `:quiescence_unknown`.
[Stop and cleanup](../../02_commands/02_04_stop_or_time_out/README.md)

## Run the tests

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/03_security_and_policy/03_06_enforce_execution_limits/example_test.exs \
  --include integration
```

The Docker checks use a local engine with runc, cgroup v2, and an
installed Alpine image. The test reads the task, memory, and CPU
limits from the running container's cgroup. It fills only that
container's temporary mount and checks the space error. It also checks
that a rejected requirement releases a borrowed checkout. A simulated
engine response verifies that Workspace refuses a requirement for an
unavailable controller.

The memory and Docker command tests pass their output barrier before
checking the timeout and save behavior. Run the same test command
without the Docker environment variables for the memory checks.
[Integration tests](example_test.exs)
