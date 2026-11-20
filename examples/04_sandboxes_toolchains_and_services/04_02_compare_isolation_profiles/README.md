# 04.02 Compare isolation profiles

Open the same saved tree with different profiles. Read the report with
the approved tool for each provider. Check the capabilities that
Workspace recorded when it opened the handle.

The example reuses the report reader from 03.03. Local uses an absolute
path to its approved executable. Memory and the container runners use
`"cat"`. Each command reads the same relative path.
[Approved report reader](../../03_security_and_policy/03_03_limit_tools_and_dependencies/example.ex)

| Provider | Exact isolation value | What the example checks |
| --- | --- | --- |
| Memory | `:mediated` | The virtual tool reads the report in the memory tree. It cannot open the outside host fixture. |
| Local | `:process` | The host executable reads the report. It can also read the outside fixture with the host user's permissions. |
| Docker | `:container` | The report runs in a container with runtime `runc`. The outside fixture is unavailable. |
| gVisor | `:gvisor` | The same container workload selects `runsc` when the local engine lists it. |

## Require a specific runtime

Set both the provider and the requirement in the host profile. This
profile needs a local Docker engine with an installed image and a
registered `runsc` runtime. [Docker runtimes](https://docs.docker.com/engine/daemon/alternative-runtimes/) ·
[gVisor Docker guide](https://gvisor.dev/docs/user_guide/quick_start/docker/)

```elixir
config :jido_workspace,
  profiles: %{
    review: %{
      provider: :gvisor,
      image: "alpine:3.20",
      policy: :full_access,
      store: "reports",
      tools: ["cat"],
      require: %{isolation: :gvisor, network: :disabled}
    }
  }
```

Use a saved reference from the `"reports"` store with a file at
`reports/report.txt`. [Save and reopen a tree](../../README.md#save-and-reopen-after-a-beam-restart)

```elixir
alias Jido.Workspace
alias Jido.Workspace.Examples.ReadWithApprovedTool

{:ok, workspace} = Workspace.open(profile: :review, from: snapshot)

try do
  {:ok, %{capabilities: %{isolation: :gvisor, runtime: "runsc"}}} =
    Workspace.info(workspace)

  {:ok, report} = ReadWithApprovedTool.read(workspace, "cat", "reports/report.txt")
  report
after
  :ok = Workspace.close(workspace)
end
```

Workspace matches `require.isolation` exactly. A `:docker` profile with
an isolation requirement of `:gvisor` returns `:unsupported_capability`.
A `:gvisor` profile returns `:runtime_unavailable` when the engine does
not list `runsc`. The error details identify the missing runtime.
For each command, Workspace selects the configured runtime explicitly.

Open checks registration. If the engine rejects a later container
create and confirms removal, run returns `:start_failed`. The tree
stays available for edits and saves. If cleanup cannot be confirmed,
Workspace keeps writes and saves blocked.

## Run the comparison

```sh
mix test examples/04_sandboxes_toolchains_and_services/04_02_compare_isolation_profiles/example_test.exs \
  --include integration

JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/04_sandboxes_toolchains_and_services/04_02_compare_isolation_profiles/example_test.exs \
  --include integration
```

The Docker test reads the actual container runtime from Docker after
each successful report run. If the engine lacks `runsc`, the test
checks the refusal and verifies that open leaves no owned root.
The local verification used runc and exercised this refusal path.
Live gVisor execution requires an engine with `runsc`.

A separate fault test simulates a runtime that is listed at open and
later rejects container creation. It checks that the sole launch
attempt selects `runsc`, that no container remains, and that the caller
can still edit and save the tree. [Integration tests](example_test.exs)
