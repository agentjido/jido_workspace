defmodule Jido.Workspace.ProfileSession do
  @moduledoc false

  use GenServer, restart: :temporary, shutdown: 60_000

  alias Jido.Workspace.{CommandIO, Error, Execution, Info, Policy, Profile}
  alias Jido.Workspace.{ProfileProvider, SnapshotStore}

  # Cooperative runners get a short interval to confirm quiescence.
  @stop_grace 1_250
  @default_write_stream_bytes 64 * 1024 * 1024

  def start({id, owner, profile, capture, infrastructure}, timeout) do
    # The handle retains a release confirmation even after its controller stops.
    release = :atomics.new(1, signed: false)
    deadline = now() + timeout
    args = {id, owner, profile, infrastructure, self(), deadline, release}

    with {:ok, pid} <- DynamicSupervisor.start_child(__MODULE__.Supervisor, {__MODULE__, args}),
         :ok <- await_open(pid, capture, max(0, deadline - now())) do
      GenServer.cast(pid, :accept_open)
      {:ok, {:profile, {pid, release}}}
    end
  end

  defp await_open(pid, capture, timeout) do
    GenServer.call(pid, {:open, capture}, timeout)
  catch
    :exit, {:timeout, _} ->
      GenServer.cast(pid, :cancel_open)
      {:error, :open_timeout}

    :exit, _ ->
      {:error, :cleanup_unconfirmed}
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def call(pid, message) do
    GenServer.call(pid, message, :infinity)
  catch
    :exit, _ -> {:error, :closed}
  end

  def close({pid, release}, timeout) do
    if :atomics.get(release, 1) == 1,
      do: :ok,
      else: GenServer.call(pid, {:close, now() + timeout}, timeout)
  catch
    :exit, _ ->
      if :atomics.get(release, 1) == 1, do: :ok, else: {:error, :cleanup_unconfirmed}
  end

  @impl true
  def format_status(%{state: %{profile: %{provider: {module, _}} = profile} = state} = status) do
    state = %{state | profile: %{profile | provider: {module, :redacted}}, provider: :redacted}
    CommandIO.redact_status(%{status | state: state})
  end

  def format_status(status), do: CommandIO.redact_status(status)

  @impl true
  def init({id, owner, profile, infrastructure, opener, deadline, release}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       id: id,
       owner: owner,
       monitor: Process.monitor(owner),
       opening: %{opener: opener, monitor: Process.monitor(opener), deadline: deadline},
       profile: profile,
       infrastructure: infrastructure,
       provider: nil,
       capabilities: nil,
       release: release,
       job: nil,
       batch: nil,
       output: nil,
       closing: nil,
       fence: nil
     }}
  end

  @impl true
  def handle_call({:open, capture}, _, %{provider: nil} = state) do
    scope = %{
      id: state.id,
      owner: state.owner,
      opener: state.opening.opener,
      deadline: state.opening.deadline,
      infrastructure: state.infrastructure,
      confirmation: state.release
    }

    with :ok <- check_open(state),
         {:ok, provider, capabilities} <-
           ProfileProvider.open(state.profile, capture, scope) do
      finish_open(%{state | provider: provider, capabilities: capabilities})
    else
      {:error, _} = error -> {:stop, :normal, error, state}
    end
  end

  def handle_call({:close, deadline}, from, state) do
    closing = await_release(state.closing || %{}, from, deadline - now())
    close_when_idle(%{state | closing: closing})
  end

  def handle_call(:info, _, state) do
    execution_id = if match?(%{kind: :run}, state.job), do: state.job.id

    info = %Info{
      id: state.id,
      owner: state.owner,
      policy: state.profile.policy,
      session: if(execution_id, do: :running, else: :stopped),
      phase: phase(state),
      active_execution_id: execution_id,
      infrastructure: state.infrastructure,
      command_limits: Profile.command_limits(state.profile),
      capabilities: state.capabilities
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call({:cancel_execution, id}, _, %{job: %{kind: :run, id: id} = job} = state) do
    job = request_stop(job)
    {:reply, :ok, %{state | job: job}}
  end

  def handle_call({:cancel_execution, _}, _, state),
    do: {:reply, {:error, :execution_not_active}, state}

  def handle_call({:command_output, id, offset}, _, %{output: %{id: id, buffer: buffer}} = state),
    do: {:reply, CommandIO.read(buffer, offset), state}

  def handle_call({:command_output, _, _}, _, state),
    do: {:reply, {:error, :output_unavailable}, state}

  def handle_call({:upload, ref, :abort}, {client, _}, state) do
    case state.job do
      %{kind: :upload, ref: ^ref, client: ^client} ->
        {result, state} = finish_upload(state, :abort)
        {:reply, result, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call(_, _, %{closing: closing} = state) when not is_nil(closing),
    do: {:reply, {:error, :closed}, state}

  def handle_call(_, _, %{fence: reason} = state) when not is_nil(reason),
    do: {:reply, {:error, reason}, state}

  def handle_call(
        {:command_input, id, bytes},
        _,
        %{job: %{kind: :run, id: id} = job, output: %{buffer: buffer}} = state
      ) do
    result =
      if job.stdin == :pipe and :atomics.get(job.stop, 1) == 0,
        do: CommandIO.input(buffer, bytes),
        else: {:error, :input_closed}

    {:reply, result, state}
  end

  def handle_call({:command_input, _, _}, _, state),
    do: {:reply, {:error, :execution_not_active}, state}

  def handle_call({:command_connector, id, port}, _, state) do
    {:reply, command_connector(state, id, port), state}
  end

  def handle_call(
        {:upload, ref, action},
        {client, _},
        %{job: %{kind: :upload, ref: ref, client: client}} = state
      ),
      do: upload_action(state, action)

  def handle_call({:upload, _, _}, _, state), do: {:reply, {:error, :closed}, state}

  def handle_call({:profile_file, operation, args}, _, %{job: job} = state)
      when is_nil(job) or (operation == :read and job.kind == :upload) do
    result = file_result(state.provider, state.profile.policy, operation, args)
    {:reply, result, fence_work(state, result)}
  end

  def handle_call(_, _, %{job: job} = state) when not is_nil(job),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:begin_upload, path}, {client, _}, state) do
    result =
      with :ok <- Policy.authorize(state.profile.policy, :write),
           do: write_result(ProfileProvider.begin_upload(state.provider, path))

    case result do
      {:ok, stage} ->
        job = %{
          kind: :upload,
          path: path,
          ref: make_ref(),
          client: client,
          client_monitor: Process.monitor(client),
          stage: stage,
          remaining:
            Map.get(state.profile.limits, :write_stream_bytes, @default_write_stream_bytes)
        }

        {:reply, {:ok, job.ref}, %{state | job: job}}

      error ->
        {:reply, error, fence_work(state, error)}
    end
  end

  def handle_call({:profile_run, argv, opts}, from, state) do
    case start_command(state, argv, opts, from) do
      {:ok, state} -> {:noreply, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:profile_find, path, needle}, from, state) do
    with :ok <- Policy.authorize(state.profile.policy, :read) do
      task =
        async(fn ->
          ProfileProvider.find(state.provider, path, needle, state.profile.discovery)
        end)

      {:noreply, %{state | job: %{kind: :find, task: task, from: from, timer: nil}}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:profile_batch, steps}, from, state) do
    batch = %{
      from: from,
      steps: steps,
      index: 1,
      results: [],
      deadline: now() + Map.get(state.profile.limits, :batch_timeout_ms, 60_000),
      output_left: Map.get(state.profile.limits, :batch_output_limit, 1_048_576)
    }

    advance_batch(%{state | batch: batch})
  end

  def handle_call(:save, from, state) do
    with :ok <- Policy.authorize(state.profile.policy, :save),
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
  def handle_cast(:accept_open, state) do
    Process.demonitor(state.opening.monitor, [:flush])
    {:noreply, %{state | opening: nil}}
  end

  def handle_cast(:cancel_open, state), do: release_unowned(state)

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

  def handle_info({:close_deadline, token}, %{closing: waiters} = state) when is_map(waiters) do
    case Map.pop(waiters, token) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, closing} ->
        GenServer.reply(from, {:error, :cleanup_unconfirmed})
        {:noreply, %{state | closing: closing}}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{opening: %{monitor: ref}} = state),
    do: release_unowned(state)

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref, provider: nil} = state),
    do: {:noreply, %{state | monitor: nil}}

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: release_unowned(state)

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{job: %{kind: :upload, client_monitor: ref}} = state
      ) do
    {_, state} = finish_upload(state, :abort)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{job: %{client_monitor: ref} = job} = state),
    do: {:noreply, %{state | job: request_stop(job)}}

  def handle_info({:DOWN, ref, :process, _, _}, %{job: %{task: %{ref: ref}} = job} = state) do
    result = if job.kind in [:run, :batch_file], do: :quiescence_unknown, else: :operation_failed
    complete(job, {:error, result}, state)
  end

  def handle_info(_, state), do: {:noreply, state}

  defp check_open(%{opening: opening} = state) do
    with :ok <- check_process(state.owner, state.monitor, :owner_unavailable),
         :ok <- check_process(opening.opener, opening.monitor, :opener_unavailable) do
      if now() >= opening.deadline, do: {:error, :open_timeout}, else: :ok
    end
  end

  defp check_process(_, nil, error), do: {:error, error}

  defp check_process(pid, monitor, error) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> {:error, error}
    after
      0 ->
        if node(pid) == node() and not Process.alive?(pid),
          do: {:error, error},
          else: :ok
    end
  end

  defp finish_open(state) do
    with :ok <- check_open(state),
         :ok <- ProfileProvider.confirm_open(state.provider, state.opening.deadline) do
      {:reply, :ok, state}
    else
      {:error, _} = error ->
        {:stop, :normal, ProfileProvider.release_failed_open(state.provider, error), state}
    end
  end

  defp release_unowned(%{provider: nil} = state), do: {:stop, :normal, state}

  defp release_unowned(state) do
    close_when_idle(%{state | monitor: nil, closing: state.closing || %{}})
  end

  defp close_when_idle(%{job: nil} = state), do: start_release(state)

  defp close_when_idle(%{job: %{kind: :upload}} = state) do
    {_, state} = finish_upload(state, :abort)
    start_release(state)
  end

  defp close_when_idle(%{job: %{kind: :run, client_monitor: ref} = job} = state)
       when is_reference(ref),
       do: {:noreply, %{state | job: request_stop(job)}}

  defp close_when_idle(state), do: {:noreply, state}

  defp async(fun), do: Task.Supervisor.async(__MODULE__.Tasks, fun)

  defp file_result(provider, policy, operation, args) do
    action = if operation in [:read, :list], do: :read, else: :write

    with :ok <- Policy.authorize(policy, action) do
      result = ProfileProvider.file(provider, operation, args)
      if action == :write, do: write_result(result), else: result
    end
  end

  defp upload_action(%{job: job} = state, {:chunk, bytes})
       when byte_size(bytes) <= job.remaining do
    case write_result(ProfileProvider.append_upload(state.provider, job.stage, bytes)) do
      {:ok, stage} ->
        {:reply, :ok,
         %{state | job: %{job | stage: stage, remaining: job.remaining - byte_size(bytes)}}}

      error ->
        {:reply, error, fence_work(state, error)}
    end
  end

  defp upload_action(state, {:chunk, _}), do: {:reply, {:error, :transfer_limit}, state}

  defp upload_action(state, :commit) do
    {result, state} = finish_upload(state, :commit)
    {:reply, result, state}
  end

  defp finish_upload(%{job: job} = state, action) do
    result =
      case action do
        :abort -> ProfileProvider.abort_upload(state.provider)
        :commit -> commit_upload(state.provider, job)
      end

    Process.demonitor(job.client_monitor, [:flush])
    result = write_result(result)
    {result, fence_work(%{state | job: nil}, result)}
  end

  defp commit_upload(provider, job) do
    with :ok <- check_process(job.client, job.client_monitor, :closed) do
      ProfileProvider.commit_upload(provider, job.path, job.stage)
    else
      error -> with :ok <- ProfileProvider.abort_upload(provider), do: error
    end
  end

  defp write_result({:error, {:sandbox_unavailable, _}}), do: {:error, :quiescence_unknown}
  defp write_result(result), do: result

  defp fence_work(state, {:error, reason})
       when reason in [:quiescence_unknown, :lease_revoked],
       do: %{state | fence: reason}

  defp fence_work(state, _), do: state

  defp command_connector(%{capabilities: %{service_ports: ports}} = state, id, port) do
    with true <- port in ports,
         %{kind: :run, id: ^id, stop: stop} <- state.job,
         0 <- :atomics.get(stop, 1) do
      CommandIO.connector(state.output.buffer)
    else
      false -> {:error, {:policy_denied, :connect}}
      _ -> {:error, :execution_not_active}
    end
  end

  defp command_connector(_, _, _), do: {:error, {:unsupported_capability, :service_ports}}

  defp start_command(state, [tool | _] = argv, opts, from) do
    with :ok <- Policy.authorize(state.profile.policy, :execute),
         true <- Profile.allows_tool?(state.profile, tool),
         :ok <- ProfileProvider.admit_stdin(state.capabilities, opts.stdin),
         :ok <- ProfileProvider.admit_command_reference(state.profile, state.infrastructure, opts) do
      opts = Profile.limit_run(state.profile, opts)
      id = "execution-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      started = now()
      stop = :atomics.new(1, signed: false)
      cooperative = state.profile.provider == :memory or is_tuple(state.profile.provider)
      buffer = CommandIO.open(opts.output_limit, cooperative)
      deadline = started + opts.timeout_ms

      connector = get_in(state.profile, [:service, :connector])
      client = from || (state.batch && state.batch.from)

      opts =
        Map.merge(opts, %{
          id: id,
          stop: stop,
          deadline: deadline,
          io_buffer: buffer,
          connector: connector
        })

      provider = state.provider
      task = async(fn -> ProfileProvider.run(provider, argv, opts) end)

      timer =
        if cooperative, do: stop_timer(task.ref, max(0, deadline - now()) + @stop_grace)

      job = %{
        kind: :run,
        id: id,
        task: task,
        from: from,
        started: started,
        argv: argv,
        stop: stop,
        timer: timer,
        stdin: opts.stdin,
        client_monitor:
          if(opts.stdin == :pipe or connector != nil, do: Process.monitor(elem(client, 0)))
      }

      :telemetry.execute(
        [:jido_workspace, :command, :start],
        %{system_time: System.system_time()},
        command_metadata(state.id, id)
      )

      notify_start(opts[:notify_start], id)
      {:ok, %{state | job: job, output: %{id: id, buffer: buffer}}}
    else
      false -> {:error, {:policy_denied, :execute}}
      error -> error
    end
  end

  defp notify_start(nil, _id), do: :ok

  defp notify_start({pid, ref}, id), do: send(pid, {:workspace_command_started, ref, id})

  defp request_stop(job) do
    :atomics.put(job.stop, 1, 1)

    case job.timer && Process.read_timer(job.timer) do
      remaining when is_integer(remaining) and remaining > @stop_grace ->
        Process.cancel_timer(job.timer)
        %{job | timer: stop_timer(job.task.ref, @stop_grace)}

      _ ->
        job
    end
  end

  defp stop_timer(ref, wait), do: Process.send_after(self(), {:run_timeout, ref}, wait)

  defp complete(%{kind: :release}, :ok, state) do
    :atomics.put(state.release, 1, 1)
    reply_to_close(state.closing, :ok)
    {:stop, :normal, state}
  end

  defp complete(%{kind: :release}, _, state) do
    reply_to_close(state.closing, {:error, :cleanup_unconfirmed})

    if state.monitor,
      do: {:noreply, %{state | closing: %{}, job: nil}},
      else: {:stop, :normal, state}
  end

  defp complete(job, result, state) do
    if job.timer, do: Process.cancel_timer(job.timer)
    if ref = job[:client_monitor], do: Process.demonitor(ref, [:flush])
    state = finish_output(job, state)
    reply = reply_for(job, result, state.id)
    state = fence_work(%{state | job: nil}, result)
    finish_job(job, reply, state)
  end

  defp finish_job(job, reply, %{batch: nil} = state) do
    GenServer.reply(job.from, reply)
    if state.closing, do: start_release(state), else: {:noreply, state}
  end

  defp finish_job(_, :ok, state), do: record_step(state, :ok, 0)

  defp finish_job(_, {:ok, %Execution{status: :exited, exit_status: 0} = execution}, state),
    do: record_step(state, execution, byte_size(execution.output))

  defp finish_job(_, {:ok, %Execution{} = execution}, state), do: finish_batch(state, execution)

  defp finish_job(_, {:error, reason}, state), do: halt_batch(state, reason)

  defp advance_batch(%{batch: %{steps: []}} = state), do: finish_batch(state, nil)

  defp advance_batch(%{batch: %{steps: [step | _], deadline: deadline}} = state) do
    remaining = deadline - now()

    cond do
      state.closing -> halt_batch(state, :closed)
      remaining <= 0 -> halt_batch(state, :batch_timeout)
      true -> start_batch_step(state, step, remaining)
    end
  end

  defp start_batch_step(state, {:run, argv, opts}, remaining) do
    opts = %{
      opts
      | timeout_ms: min(opts.timeout_ms, remaining),
        output_limit: min(opts.output_limit, state.batch.output_left)
    }

    case start_command(state, argv, opts, nil) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> halt_batch(state, reason)
    end
  end

  defp start_batch_step(%{provider: provider, profile: %{policy: policy}} = state, {op, args}, _) do
    task = async(fn -> file_result(provider, policy, op, args) end)
    {:noreply, %{state | job: %{kind: :batch_file, task: task, timer: nil}}}
  end

  defp record_step(%{batch: %{steps: [_ | rest]} = batch} = state, result, used) do
    batch = %{
      batch
      | steps: rest,
        index: batch.index + 1,
        results: [result | batch.results],
        output_left: batch.output_left - used
    }

    advance_batch(%{state | batch: batch})
  end

  defp halt_batch(%{batch: %{steps: [step | _]}} = state, reason) do
    operation = elem(step, 0)

    error =
      case reason do
        %Error{} = error -> %{error | resource: state.id, operation: operation}
        _ -> Error.from_reason(operation, state.id, reason)
      end

    finish_batch(state, error)
  end

  defp finish_batch(%{batch: batch} = state, failure) do
    results = Enum.reverse(batch.results)

    report =
      if failure do
        %{status: :halted, results: results, failure: %{index: batch.index, result: failure}}
      else
        %{status: :completed, results: results}
      end

    GenServer.reply(batch.from, {:ok, report})
    state = %{state | batch: nil}
    if state.closing, do: start_release(state), else: {:noreply, state}
  end

  defp finish_output(%{kind: :run}, %{output: output} = state),
    do: %{state | output: %{output | buffer: CommandIO.close(output.buffer)}}

  defp finish_output(_, state), do: state

  defp reply_for(%{kind: :run} = job, result, workspace_id) do
    duration = max(0, now() - job.started)
    reply = command_result(job, result, workspace_id, duration)

    :telemetry.execute(
      [:jido_workspace, :command, :stop],
      %{duration_ms: duration},
      Map.merge(command_metadata(workspace_id, job.id), command_outcome(reply))
    )

    reply
  end

  defp reply_for(_, result, _), do: result

  defp command_result(job, {:ok, result}, _workspace_id, duration) do
    {:ok,
     %Execution{
       id: job.id,
       command: job.argv,
       status: result.status,
       exit_status: result.exit_status,
       duration_ms: duration,
       output: result.output,
       truncated: result.truncated,
       files: nil,
       after_files: nil
     }}
  end

  defp command_result(job, {:error, reason}, workspace_id, _duration) do
    error =
      case reason do
        %Error{} -> reason
        _ -> Error.from_reason(:run, workspace_id, reason)
      end

    {:error, %{error | details: Map.put(error.details, :execution_id, job.id)}}
  end

  defp command_metadata(workspace_id, execution_id),
    do: %{workspace_id: workspace_id, execution_id: execution_id}

  defp command_outcome({:ok, execution}),
    do: %{status: execution.status, exit_status: execution.exit_status}

  defp command_outcome({:error, error}), do: %{status: :error, error_code: error.code}

  defp phase(%{closing: closing}) when not is_nil(closing), do: :closing
  defp phase(%{fence: reason}) when not is_nil(reason), do: reason
  defp phase(%{job: %{kind: :run}}), do: :running
  defp phase(%{batch: batch}) when not is_nil(batch), do: :batching
  defp phase(%{job: %{kind: :save}}), do: :saving
  defp phase(%{job: %{kind: :find}}), do: :finding
  defp phase(%{job: %{kind: :upload}}), do: :writing
  defp phase(_), do: :ready

  defp await_release(waiters, from, remaining) when remaining > 0 do
    token = make_ref()
    timer = Process.send_after(self(), {:close_deadline, token}, remaining)
    Map.put(waiters, token, {from, timer})
  end

  defp await_release(waiters, from, _) do
    GenServer.reply(from, {:error, :cleanup_unconfirmed})
    waiters
  end

  defp start_release(state) do
    task = async(fn -> ProfileProvider.close(state.provider) end)
    {:noreply, %{state | job: %{kind: :release, task: task}}}
  end

  defp reply_to_close(waiters, result) do
    Enum.each(waiters, fn {_token, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, result)
    end)
  end

  defp snapshot_store(%{store: store}), do: {:ok, store}
  defp snapshot_store(_), do: {:error, :snapshot_store_unconfigured}
  defp now, do: System.monotonic_time(:millisecond)
end
