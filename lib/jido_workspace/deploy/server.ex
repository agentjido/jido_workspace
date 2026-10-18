defmodule Jido.Workspace.Deploy.Server do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Jido.Workspace.Deploy.{Plan, Snapshot}

  def start_link({key, target}),
    do:
      GenServer.start_link(__MODULE__, {key, target},
        name: {:via, Registry, {Jido.Workspace.Deploy.Registry, key}}
      )

  def init({key, target}) do
    with {:ok, sandbox} <- Jido.Workspace.Sandbox.claim_deployment(target.sandbox, key) do
      {:ok,
       %{
         target: target,
         execution_sandbox: sandbox,
         plans: %{},
         operations: %{},
         task: nil,
         blocked: false,
         sandbox_monitor: Process.monitor(target.sandbox.pid)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def handle_call(:inspect, _, state) do
    result =
      with {:ok, observation} <- executor(state.target).inspect(state.target) do
        {:ok, Map.put(observation, :controller, %{blocked: state.blocked})}
      end

    {:reply, result, state}
  end

  def handle_call(:target, _, state), do: {:reply, state.target, state}

  def handle_call({:prepare, artifact, opts}, _, state), do: prepare(state, artifact, opts, nil)

  def handle_call({:recover, id, artifact, opts}, _, state) do
    case state.operations[id] do
      %{status: status} when status != :running -> prepare(state, artifact, opts, id)
      _ -> {:reply, {:error, :recovery_operation_not_found_or_running}, state}
    end
  end

  def handle_call({:apply, plan}, _, state) do
    permission = Jido.Workspace.Sandbox.authorize(state.target.sandbox, :deploy)

    cond do
      permission != :ok ->
        {:reply, permission, state}

      state.plans[plan.id] != plan ->
        {:reply, {:error, :unknown_or_changed_plan}, state}

      state.operations[plan.id] ->
        {:reply, {:ok, plan.id}, state}

      state.task != nil ->
        {:reply, {:error, :busy}, state}

      state.blocked and plan.recovery_of == nil ->
        {:reply, {:error, :recovery_required}, state}

      true ->
        target = %{state.target | sandbox: state.execution_sandbox}
        owner = self()
        notify = fn phase, evidence -> send(owner, {:step, plan.id, phase, evidence}) end

        task =
          Task.Supervisor.async_nolink(Jido.Workspace.Deploy.Tasks, fn ->
            result = execute(target, plan, notify)
            %{result: result, after: executor(target).inspect(target)}
          end)

        record = %{
          id: plan.id,
          plan_id: plan.id,
          recovery_of: plan.recovery_of,
          target: %{id: target.id, name: target.name, stage: target.stage, roles: target.roles},
          snapshot_id: plan.artifact.snapshot.id,
          digest: plan.artifact.snapshot.digest,
          version: plan.artifact.version,
          status: :running,
          before: plan.expected,
          started_at: DateTime.utc_now(),
          steps: []
        }

        {:reply, {:ok, plan.id},
         %{state | task: {task, plan.id}, operations: Map.put(state.operations, plan.id, record)}}
    end
  end

  def handle_call({:status, id}, _, state) do
    result =
      case Map.fetch(state.operations, id) do
        {:ok, record} -> {:ok, record}
        :error -> {:error, :operation_not_found}
      end

    {:reply, result, state}
  end

  def handle_info(
        {ref, %{result: result, after: observation}},
        %{task: {%Task{ref: ref}, id}} = state
      ) do
    Process.demonitor(ref, [:flush])

    {status, evidence} =
      case result do
        {:ok, evidence} -> {:succeeded, evidence}
        {:error, evidence} -> {:failed, evidence}
        {:recovery_required, evidence} -> {:recovery_required, evidence}
        other -> {:recovery_required, {:unexpected_result, other}}
      end

    record =
      Map.merge(state.operations[id], %{
        status: status,
        evidence: evidence,
        after: observation,
        finished_at: DateTime.utc_now()
      })

    {:noreply,
     %{
       state
       | task: nil,
         blocked: status == :recovery_required or (state.blocked and status != :succeeded),
         operations: Map.put(state.operations, id, record)
     }}
  end

  def handle_info({:step, id, phase, evidence}, state) do
    event = %{phase: phase, evidence: evidence, at: DateTime.utc_now()}
    {:noreply, update_in(state.operations[id].steps, &(&1 ++ [event]))}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: {%Task{ref: ref}, id}} = state) do
    record =
      Map.merge(state.operations[id], %{
        status: :recovery_required,
        evidence: {:worker_exit, reason},
        finished_at: DateTime.utc_now()
      })

    {:noreply,
     %{state | task: nil, blocked: true, operations: Map.put(state.operations, id, record)}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{sandbox_monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  defp prepare(state, artifact, opts, recovery_of) do
    with true <- artifact.kind == state.target.kind,
         true <- Jido.Workspace.Deploy.Artifact.valid?(artifact),
         true <- valid_options?(state.target.kind, opts),
         {:ok, observation} <- executor(state.target).inspect(state.target) do
      id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      plan = %Plan{
        id: id,
        target: state.target.name,
        artifact: artifact,
        expected: observation.identity,
        recipe: Keyword.get(opts, :recipe),
        preflight: Keyword.get(opts, :preflight),
        verify: Keyword.get(opts, :verify),
        recovery_of: recovery_of
      }

      {:reply, {:ok, plan}, put_in(state.plans[id], plan)}
    else
      false -> {:reply, {:error, :invalid_artifact_or_target_kind}, state}
      error -> {:reply, error, state}
    end
  end

  defp execute(target, plan, notify) do
    with true <- Snapshot.valid?(plan.artifact.snapshot),
         {:ok, observation} <- executor(target).inspect(target),
         true <- observation.identity == plan.expected do
      notify.(:check_target, :passed)
      executor(target).execute(target, plan, notify)
    else
      false -> {:error, :stale_target_or_payload}
      error -> {:error, error}
    end
  end

  defp valid_options?(:source, opts),
    do:
      Keyword.keys(opts) -- [:recipe] == [] and
        Jido.Workspace.Deploy.Recipe.valid?(Keyword.get(opts, :recipe))

  defp valid_options?(:otp, opts) do
    Keyword.keys(opts) -- [:preflight, :verify] == [] and
      valid_callback?(Keyword.get(opts, :preflight)) and
      valid_callback?(Keyword.get(opts, :verify))
  end

  defp valid_callback?(nil), do: true

  defp valid_callback?({module, function, args}),
    do: is_atom(module) and is_atom(function) and is_list(args)

  defp valid_callback?(_), do: false

  defp executor(%{kind: :otp}), do: Jido.Workspace.Deploy.OTP
  defp executor(%{kind: :source}), do: Jido.Workspace.Deploy.Source
end
