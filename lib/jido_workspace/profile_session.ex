defmodule Jido.Workspace.ProfileSession do
  @moduledoc false

  use GenServer, restart: :temporary, shutdown: 60_000

  alias Jido.Workspace.{Execution, Info, Policy, Profile, ProfileProvider, SnapshotStore}

  def start(args), do: DynamicSupervisor.start_child(__MODULE__.Supervisor, {__MODULE__, args})
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def call(pid, message) do
    GenServer.call(pid, message, :infinity)
  catch
    :exit, _ -> {:error, :closed}
  end

  @impl true
  def init({id, owner, profile, capture}) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)

    case ProfileProvider.open(profile, capture) do
      {:ok, provider} ->
        {:ok,
         %{
           id: id,
           owner: owner,
           monitor: monitor,
           profile: profile,
           provider: provider,
           job: nil,
           closing: nil,
           uncertain: false
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:close, from, %{job: job} = state) when not is_nil(job) do
    {:noreply, %{state | closing: [from | state.closing || []]}}
  end

  def handle_call(:close, from, state), do: release([from], state)

  def handle_call(:info, _, state) do
    session = if match?(%{kind: :run}, state.job), do: :running, else: :stopped

    {:reply,
     {:ok,
      %Info{id: state.id, owner: state.owner, policy: state.profile.policy, session: session}},
     state}
  end

  def handle_call(_, _, %{closing: closing} = state) when not is_nil(closing),
    do: {:reply, {:error, :closed}, state}

  def handle_call(_, _, %{uncertain: true} = state),
    do: {:reply, {:error, :quiescence_unknown}, state}

  def handle_call(_, _, %{job: job} = state) when not is_nil(job),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:profile_file, operation, args}, _, state) do
    action = if operation in [:read, :list], do: :read, else: :write

    result =
      with :ok <- Policy.authorize(state.profile.policy, action),
           do: ProfileProvider.file(state.provider, operation, args)

    {:reply, result, state}
  end

  def handle_call({:profile_run, [tool | _] = argv, opts}, from, state) do
    with :ok <- Policy.authorize(state.profile.policy, :execute),
         true <- Profile.allows_tool?(state.profile, tool) do
      task = async(fn -> ProfileProvider.run(state.provider, argv, opts) end)

      timer =
        if state.profile.provider == :memory,
          do: Process.send_after(self(), {:run_timeout, task.ref}, opts.timeout_ms)

      job = %{kind: :run, task: task, from: from, started: now(), argv: argv, timer: timer}
      {:noreply, %{state | job: job}}
    else
      false -> {:reply, {:error, {:policy_denied, :execute}}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:save, from, state) do
    with :ok <- Policy.authorize(state.profile.policy, :write),
         {:ok, store} <- snapshot_store(state.profile) do
      task =
        async(fn ->
          with {:ok, capture} <- ProfileProvider.capture(state.provider),
               do: SnapshotStore.put(store, capture)
        end)

      {:noreply, %{state | job: %{kind: :save, task: task, from: from, timer: nil}}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :unsupported_capability}, state}

  @impl true
  def handle_info({ref, result}, %{job: %{task: %{ref: ref}} = job} = state) do
    Process.demonitor(ref, [:flush])
    complete(job, result, state)
  end

  def handle_info({:run_timeout, ref}, %{job: %{task: %{ref: ref}} = job} = state) do
    case Task.shutdown(job.task, :brutal_kill) do
      {:ok, result} ->
        complete(job, result, state)

      _ ->
        complete(job, {:error, :quiescence_unknown}, state)
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref, job: nil} = state),
    do: release([], state)

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:noreply, %{state | closing: state.closing || []}}

  def handle_info({:DOWN, ref, :process, _, _}, %{job: %{task: %{ref: ref}} = job} = state) do
    result = if job.kind == :run, do: :quiescence_unknown, else: :operation_failed
    complete(job, {:error, result}, state)
  end

  def handle_info(_, state), do: {:noreply, state}

  defp async(fun), do: Task.Supervisor.async(__MODULE__.Tasks, fun)

  defp complete(job, result, state) do
    if job.timer, do: Process.cancel_timer(job.timer)
    GenServer.reply(job.from, result_for(job, result))

    state = %{
      state
      | job: nil,
        uncertain: state.uncertain or result == {:error, :quiescence_unknown}
    }

    case state.closing do
      nil -> {:noreply, state}
      waiters -> release(waiters, state)
    end
  end

  defp result_for(%{kind: :run} = job, {:ok, result}) do
    {:ok,
     %Execution{
       id: "execution-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
       command: job.argv,
       status: result.status,
       exit_status: result.exit_status,
       duration_ms: max(0, now() - job.started),
       output: result.output,
       truncated: result.truncated,
       files: nil,
       after_files: nil
     }}
  end

  defp result_for(_, result), do: result

  defp release(waiters, state) do
    case ProfileProvider.close(state.provider) do
      :ok ->
        Enum.each(waiters, &GenServer.reply(&1, :ok))
        {:stop, :normal, state}

      _ ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, :cleanup_unconfirmed}))

        if Process.alive?(state.owner),
          do: {:noreply, %{state | closing: nil, uncertain: true}},
          else: {:stop, :normal, state}
    end
  end

  defp snapshot_store(%{store: store}), do: {:ok, store}
  defp snapshot_store(_), do: {:error, :snapshot_store_unconfigured}
  defp now, do: System.monotonic_time(:millisecond)
end
