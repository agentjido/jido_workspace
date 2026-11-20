# 08.04 Upgrade an OTP release

Start an OTP release from a saved Workspace tree. Upgrade it while its counter is live, then downgrade it without losing the latest state. A third release fails in `code_change/3`. Observe the restart and recover explicitly from the booted state.

## Save the release trees

Run from the repository root. The fixture builds three small Erlang releases with the installed Erlang/OTP. It uses `.appup` files for the state callbacks and `:systools.make_relup/4` for the release transitions.

```sh
export WORKSPACE_RESULTS_DIR="$(mktemp -d)"
MIX_ENV=test iex -S mix
```

```elixir
alias Jido.Workspace
alias Jido.Workspace.{Deploy, Sandbox}
alias Jido.Workspace.Deploy.{Artifact, OTP, Snapshot}
alias Jido.Workspace.Deploy.Test.Releases

root = System.fetch_env!("WORKSPACE_RESULTS_DIR")
Application.put_env(:jido_workspace, :stores, %{"releases" => Path.join(root, "snapshots")})
Application.put_env(:jido_workspace, :profiles, %{
  builder: %{provider: :memory, policy: :workspace_write, store: "releases"},
  reader: %{provider: :memory, policy: :read_only, store: "releases"}
})

saved = for {version, fixture} <- Releases.build(Path.join(root, "build")), into: %{} do
  {:ok, workspace} = Workspace.open(profile: :builder)

  try do
    for {path, %{bytes: bytes}} <- fixture.snapshot.entries do
      :ok = Workspace.write(workspace, path, bytes)
    end

    {:ok, reference} = Workspace.save(workspace)
    {version, reference}
  after
    :ok = Workspace.close(workspace)
  end
end

artifact = fn version ->
  {:ok, files} = Snapshot.from_saved(Map.fetch!(saved, version), profile: :reader)
  {:ok, release} = Artifact.new(:otp, version, files)
  release
end
```

## Upgrade, downgrade, and recover

```elixir
{:ok, sandbox} = Sandbox.open(owner: self())

try do
  initial = artifact.("1")
  upgrade = artifact.("2")
  {:ok, target} = OTP.start(sandbox, "counter", initial)
  {:ok, session} = Deploy.connect(target)
  {:ok, %{identity: %{generation: generation}}} = Deploy.inspect(session)

  counter = fn -> OTP.call(target, :counter_server, :inspect, []) end
  run = fn plan ->
    {:ok, id} = Deploy.apply(session, plan)
    {:ok, record} = Deploy.await(session, id)
    record
  end

  {:ok, {pid, ~c"1", %{count: 10, requests: 0}}} = counter.()
  {:ok, plan} = Deploy.prepare(session, upgrade)
  {:ok, %{count: 17, requests: 1}} = OTP.call(target, :counter_server, :add, [7])
  %{status: :succeeded, id: upgrade_id} = run.(plan)
  {:ok, {^pid, ~c"2", %{total: 17, requests: 1}}} = counter.()
  {:ok, %{total: 27, requests: 2}} = OTP.call(target, :counter_server, :add, [5])

  {:ok, downgrade} = Deploy.recover(session, upgrade_id, initial)
  %{status: :succeeded, recovery_of: ^upgrade_id} = run.(downgrade)
  {:ok, {^pid, ~c"1", %{count: 27, requests: 2}}} = counter.()

  {:ok, plan} = Deploy.prepare(session, artifact.("3"))
  %{status: :recovery_required, id: failed} = run.(plan)

  :ok = Enum.reduce_while(1..100, {:error, :target_not_ready}, fn _, pending ->
    with {:ok, ^target} <- OTP.reconnect(target),
         {:ok, %{identity: %{generation: current}}} when current != generation <- OTP.inspect(target) do
      {:halt, :ok}
    else
      _ ->
        Process.sleep(50)
        {:cont, pending}
    end
  end)

  {:ok, %{controller: %{blocked_by: ^failed}}} = Deploy.inspect(session)
  {:ok, {restarted_pid, ~c"1", %{count: 10, requests: 0}}} = counter.()
  true = restarted_pid != pid

  {:ok, recovery} = Deploy.recover(session, failed, upgrade)
  %{status: :succeeded, recovery_of: ^failed} = run.(recovery)
  {:ok, {^restarted_pid, ~c"2", %{total: 10, requests: 0}}} = counter.()
after
  :ok = Sandbox.destroy(sandbox)
end
```

The successful transitions keep the counter PID and migrate its current state. This includes calls that finish after planning. The failed transition in this fixture causes OTP to boot the permanent release and initialize a new counter. Reconnection checks that the applications have started. Explicit recovery works from that new state.

OTP startup requires a target that reports `beam_call: true`. The local target uses the installed ERTS and OTP libraries. A Docker workspace can supply a saved release tree. A Docker target refuses OTP before it copies any files. The example covers executable mode checks, live migration, and a restart on failure. Permanent boot selection, ERTS replacement, and external state recovery are outside this workflow.

## Run the checks

```sh
mix test examples/08_deployment_and_application_workflows/08_04_upgrade_an_otp_release/example_test.exs --include integration
```

Set `JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20` to test a Docker source and the Docker target's capability refusal. Use a locally available image.
