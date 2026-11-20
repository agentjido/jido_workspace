# 06.02 Reuse a persistent machine or request a fresh one

Keep a machine and its working files after a Workspace session closes.
The host requests a machine, records its infrastructure reference, and
opens a session on that reference. Reopen the same reference to reuse
the machine. Request a fresh machine with a new request ID.

This example uses two long-lived containers on a local Docker engine.
Each has its own host-owned working directory. Commands read that
directory through a read-only bind mount. File edits go through the
provider's lease checks. Use an installed `alpine:3.20` image.

## Open, close, and reuse

Use the sample host's `MachinePool.request/2` to obtain a machine
reference. It returns the same identity for a repeat request ID in the
same pool. The host can store the reference as JSON before it opens the
Workspace session.

```elixir
directory = "examples/06_providers_and_persistent_infrastructure/06_02_reuse_or_request_a_machine"
Code.require_file(Path.join(directory, "machine_pool.ex"))
Code.require_file(Path.join(directory, "machine_provider.ex"))

alias Jido.Workspace
alias Jido.Workspace.Examples.{MachinePool, MachineProvider}

suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
root = Path.join(System.tmp_dir!(), "jido-machine-example-" <> suffix)
{:ok, pool} = MachinePool.start(root, "alpine:3.20")

Application.put_env(:jido_workspace, :profiles, %{
  build: %{
    provider: {MachineProvider, %{pool: pool}},
    infrastructure: MachinePool.provider(),
    policy: :full_access,
    require: %{network: :disabled},
    tools: ["read", "identity"]
  }
})

try do
  {:ok, machine} = MachinePool.request(pool, "build-1")
  serialized = Jason.encode!(machine)
  {:ok, workspace} = Workspace.open(profile: :build, infrastructure: machine)

  try do
    :ok = Workspace.write(workspace, "build/report.txt", "draft\n")
  after
    :ok = Workspace.close(workspace)
  end

  {:ok, reopened} = Workspace.open(profile: :build, infrastructure: Jason.decode!(serialized))

  try do
    {:ok, %{infrastructure: ^machine}} = Workspace.info(reopened)
    {:ok, %{exit_status: 0, output: "draft\n"}} =
      Workspace.run(reopened, ["read", "report.txt"], cwd: "build")
  after
    :ok = Workspace.close(reopened)
  end

  {:ok, fresh} = MachinePool.request(pool, "build-2")
  true = fresh.resource_id != machine.resource_id
  {:ok, blank} = Workspace.open(profile: :build, infrastructure: fresh)

  try do
    {:error, %{code: :not_found}} = Workspace.read(blank, "build/report.txt")
  after
    :ok = Workspace.close(blank)
  end
after
  :ok = MachinePool.destroy(pool)
  {:ok, _} = File.rm_rf(root)
end
```

## Check ownership and failure

- The profile names the provider namespace. Before it returns a handle,
  Workspace validates the reference and checks the identity that the
  provider reports. The provider also checks access to the resource.
- The provider acquires a new session lease on each open. A lease in use
  returns `:infrastructure_busy`. Releasing an attempted lease leaves
  any current lease in force.
- A stopped machine returns `:infrastructure_unavailable`. The host can
  restart it and attach the same reference. Only the host requests or
  destroys machines.
- A snapshot records the working files. An infrastructure reference
  selects a live resource. Save on a profile with a store and restore
  with `from:` on a separate profile. An attach refuses a simultaneous
  restore request so it preserves the existing tree.

The fixture registry runs in the host BEAM. These tests prove session
close, owner exit, and machine reuse on a local Docker engine. A provider
for remote machines must maintain resource and writer state outside the
Workspace controller so a fresh BEAM can recover safely.

## Run the integration tests

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/06_providers_and_persistent_infrastructure/06_02_reuse_or_request_a_machine/example_test.exs \
  --include integration
```

The live tests check the container ID and start time, persisted files,
an independent fresh tree, lease contention, owner exit, and explicit
restart of a stopped container. They verify that a separate memory
workspace can restore the snapshot. The reference validation test also
runs without Docker. [Host fixture](machine_pool.ex) · [Provider](machine_provider.ex) · [Tests](example_test.exs)
