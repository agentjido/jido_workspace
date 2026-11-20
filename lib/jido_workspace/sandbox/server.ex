defmodule Jido.Workspace.Sandbox.Server do
  @moduledoc false
  use GenServer, restart: :temporary, shutdown: 60_000
  alias Jido.Workspace.{CommandIO, FileView}
  alias Jido.Workspace.Sandbox
  alias Jido.Workspace.Sandbox.Backends.Erlexec
  alias Jido.Workspace.Sandbox.{Files, OTP}

  @release_retry_ms 5_000
  @registry Jido.Workspace.Sandbox.Registry
  @read_files [:path, :read, :read_link, :verify]
  @write_files [:mkdir, :delete, :replace_link, :move, :write_checked]
  @file_operations @read_files ++ @write_files

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def format_status(status), do: CommandIO.redact_status(status)

  def init({id, root_spec, policy, backend, opts, owner}) do
    Process.flag(:trap_exit, true)
    owner_monitor = if is_pid(owner), do: Process.monitor(owner)

    case prepare_root(root_spec) do
      {:ok, root, checkout_key} ->
        sandbox = %Sandbox{id: id, root: root, pid: self(), checkout_key: checkout_key}

        case backend.open(sandbox, opts) do
          {:ok, backend_state, capabilities} ->
            sandbox = %{sandbox | provider: capabilities.provider}
            Registry.register(@registry, id, root)

            {:ok,
             %{
               sandbox: sandbox,
               backend: backend,
               backend_state: backend_state,
               capabilities: capabilities,
               upload: nil,
               services: %{},
               deployments: %{},
               owner_monitor: owner_monitor,
               policy: policy,
               case_sensitive: checkout_key != nil or Files.case_sensitive?(root)
             }}

          {:error, reason} ->
            case release_root(sandbox) do
              :ok ->
                {:stop, reason}

              {:error, _, _} ->
                Process.send_after(self(), :release_failed_root, @release_retry_ms)
                {:ok, {:failed_open, root}}
            end
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp prepare_root({:owned, root}) do
    case File.mkdir(root) do
      :ok -> {:ok, root, nil}
      {:error, reason} -> {:error, {:root, reason}}
    end
  end

  defp prepare_root({:checkout, root}) do
    with {:ok, key} <- Files.checkout_key(root), do: {:ok, root, key}
  end

  def handle_call(_, _, {:failed_open, _} = state),
    do: {:reply, {:error, :cleanup_unconfirmed}, state}

  def handle_call(request, _, %{fence: :quiescence_unknown} = state)
      when request not in [:handle, :capabilities, :info, :destroy] and
             not (is_tuple(request) and elem(request, 0) in [:service_status, :stop_service]),
      do: {:reply, {:error, :quiescence_unknown}, state}

  def handle_call(:handle, _, state), do: {:reply, {:ok, state.sandbox}, state}
  def handle_call(:capabilities, _, state), do: {:reply, state.capabilities, state}

  # Each operation checks the controller and generation in the same server call.
  def handle_call({:claim_deployment, _}, _, %{sandbox: %{checkout_key: key}} = state)
      when not is_nil(key),
      do: {:reply, {:error, {:unsupported_capability, :checkout_deployment}}, state}

  def handle_call({:claim_deployment, key}, {owner, _}, state) do
    previous = state.deployments[key]

    if previous && previous.owner != owner && Process.alive?(previous.owner) do
      {:reply, {:error, :deployment_owned}, state}
    else
      generation = if previous, do: previous.generation + 1, else: 1
      entry = %{owner: owner, generation: generation}
      {:reply, {:ok, generation}, put_in(state.deployments[key], entry)}
    end
  end

  def handle_call({:deployment, {key, generation}, request}, from, state) do
    case state.deployments[key] do
      %{owner: owner, generation: ^generation} ->
        if Process.alive?(owner),
          do: handle_call(request, from, state),
          else: {:reply, {:error, :stale_deployment}, state}

      _ ->
        {:reply, {:error, :stale_deployment}, state}
    end
  end

  def handle_call({:deployment_call, id, module, function, args, timeout}, from, state) do
    {:reply, result, state} = handle_call({:peer, id}, from, state)

    result =
      with {:ok, peer} <- result do
        try do
          {:ok, :peer.call(peer, module, function, args, timeout)}
        catch
          kind, reason -> {:error, {:target_call, kind, reason}}
        end
      end

    {:reply, result, state}
  end

  def handle_call({:authorize, action}, _, state),
    do: {:reply, Jido.Workspace.Policy.authorize(state.policy, action), state}

  def handle_call({:location, relative}, _, state) do
    result =
      with :ok <- check_checkout(state.sandbox),
           {:ok, path} <- Files.path(state.sandbox.root, relative) do
        canonical = Path.relative_to(path, state.sandbox.root)
        key = if state.case_sensitive, do: canonical, else: String.downcase(canonical)
        {:ok, %{id: {state.sandbox.id, key}, path: canonical, sandbox: state.sandbox}}
      end

    {:reply, result, state}
  end

  def handle_call({:file_view, relative}, _, state),
    do: {:reply, file_view(state.sandbox, relative), state}

  def handle_call({:release_files, relative, version, initialize}, _, state) do
    result =
      with :ok <- Jido.Workspace.Policy.authorize(state.policy, :deploy),
           :ok <- require_capability(state, :beam_call),
           :ok <- check_checkout(state.sandbox),
           do: OTP.prepare(state.sandbox.root, relative, version, initialize)

    {:reply, result, state}
  end

  def handle_call({:files, operation, args}, _, state) when operation in @file_operations do
    action = if operation in @read_files, do: :read, else: :write

    result =
      with :ok <- Jido.Workspace.Policy.authorize(state.policy, action),
           :ok <- check_checkout(state.sandbox),
           do: apply(Files, operation, [state.sandbox.root | args])

    {:reply, result, state}
  end

  def handle_call({:files, _, _}, _, state),
    do: {:reply, {:error, :unsupported_file_operation}, state}

  def handle_call({:write, relative, bytes, mode}, _, state) do
    result =
      with :ok <- Jido.Workspace.Policy.authorize(state.policy, :write),
           :ok <- check_checkout(state.sandbox),
           do: Files.write(state.sandbox.root, relative, bytes, mode)

    {:reply, result, state}
  end

  def handle_call({:upload, {:begin, path}}, _, %{upload: nil} = state) do
    with :ok <- Jido.Workspace.Policy.authorize(state.policy, :write),
         :ok <- check_checkout(state.sandbox),
         {:ok, stage} <- Files.stage_write(state.sandbox.root, path) do
      {:reply, :ok, %{state | upload: stage}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:upload, {:chunk, bytes}}, _, %{upload: stage} = state)
      when not is_nil(stage) do
    result =
      with :ok <- check_checkout(state.sandbox), do: Files.append_stage(stage, bytes)

    {:reply, result, state}
  end

  def handle_call({:upload, :commit}, _, %{upload: stage} = state) when not is_nil(stage) do
    result = with :ok <- check_checkout(state.sandbox), do: Files.commit_stage(stage)
    finish_upload(state, result)
  end

  def handle_call({:upload, :abort}, _, state), do: finish_upload(state, :ok)

  def handle_call({:upload, _}, _, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:info, _, state) do
    services = Map.new(state.services, fn {id, service} -> {id, service_info(service)} end)

    {:reply, {:ok, %{sandbox: state.sandbox, services: services}}, state}
  end

  def handle_call({:start_service, spec}, from, state),
    do: handle_call({:start_service, spec, nil}, from, state)

  def handle_call({:start_service, spec, io_buffer}, _, state) do
    result =
      with :ok <- Jido.Workspace.Policy.authorize(state.policy, :execute) do
        with true <- valid_spec?(spec),
             :ok <- require_capability(state, if(spec.kind == :beam, do: :beam_call, else: :exec)),
             :ok <- admit_stdin(state.capabilities, spec, io_buffer),
             {:ok, view} <- file_view(state.sandbox, Map.get(spec, :dir, ".")),
             :ok <- FileView.check(Map.get(spec, :files, :current), view),
             {:ok, service} <- state.backend.start_service(state.backend_state, spec) do
          {:ok, Map.put(service, :files, view)}
        else
          false -> {:error, :invalid_service}
          error -> error
        end
      end

    case result do
      {:ok, service} ->
        id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

        {connector, service} = Map.pop(service, :connector)
        if connector && io_buffer, do: CommandIO.attach_connector(io_buffer, connector)
        if spec[:stdin] == :pipe, do: CommandIO.attach_input(io_buffer, service.handle)

        if timeout = Map.get(spec, :timeout),
          do: Process.send_after(self(), {:timeout, id}, timeout)

        {:reply, {:ok, id}, put_in(state.services[id], Map.put(service, :io_buffer, io_buffer))}

      {:error, :quiescence_unknown, service} ->
        state = put_in(state.services[service.container], service)
        {:reply, {:error, :quiescence_unknown}, Map.put(state, :fence, :quiescence_unknown)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:service_status, id}, _, state) do
    result =
      case Map.fetch(state.services, id) do
        {:ok, %{error: error}} -> {:error, error}
        {:ok, service} -> {:ok, Map.drop(service, [:handle, :io_buffer])}
        :error -> {:error, :service_not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:peer, id}, _, state) do
    result =
      case {Jido.Workspace.Policy.authorize(state.policy, :execute), state.services[id]} do
        {:ok, %{kind: :beam, handle: peer, status: :running}} ->
          {:ok, peer}

        {{:error, _} = error, _} ->
          error

        _ ->
          if(state.capabilities.beam_call,
            do: {:error, :beam_service_unavailable},
            else: {:error, {:unsupported_capability, :beam_call}}
          )
      end

    {:reply, result, state}
  end

  def handle_call({:stop_service, id}, _, state) do
    case Jido.Workspace.Policy.authorize(state.policy, :execute) do
      :ok -> stop_service(id, state)
      error -> {:reply, error, state}
    end
  end

  def handle_call(:destroy, _, state) do
    with :ok <- release(state) do
      {:stop, :normal, :ok, %{state | services: %{}, upload: nil}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_info(:release_failed_root, {:failed_open, root} = state) do
    case File.rm_rf(root) do
      {:ok, _} ->
        {:stop, :normal, state}

      {:error, _, _} ->
        Process.send_after(self(), :release_failed_root, @release_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(_, {:failed_open, _} = state), do: {:noreply, state}

  def handle_info({handle, {:data, bytes}}, state) do
    {:noreply,
     update_service(state, handle, fn service ->
       remaining = max(service.output_limit - byte_size(service.output), 0)
       if buffer = service[:io_buffer], do: CommandIO.append(buffer, bytes)

       %{
         service
         | output: service.output <> binary_part(bytes, 0, min(byte_size(bytes), remaining)),
           truncated: service.truncated or byte_size(bytes) > remaining
       }
     end)}
  end

  def handle_info({port, {:exit_status, code}}, state) do
    state =
      update_service(state, port, fn service ->
        if service.status == :running do
          case state.backend.finish_service(state.backend_state, service, code) do
            {:ok, service} -> service
            {:error, error} -> Map.merge(service, %{status: :failed, error: error})
          end
        else
          service
        end
      end)

    {:noreply, fence_unconfirmed_apple_service(state)}
  end

  def handle_info({:EXIT, port, :normal}, %{sandbox: %{provider: :apple_container}} = state)
      when is_port(port),
      do: {:noreply, state}

  def handle_info({:EXIT, port, _}, %{sandbox: %{provider: :apple_container}} = state)
      when is_port(port) do
    state =
      update_service(state, port, fn
        %{status: :running} = service ->
          Map.put(service, :cleanup_error, {:error, :quiescence_unknown})

        service ->
          service
      end)

    {:noreply, fence_unconfirmed_apple_service(state)}
  end

  def handle_info({:EXIT, port, _}, %{sandbox: %{provider: :local}} = state)
      when is_port(port) do
    {:noreply,
     update_service(state, port, fn
       %{status: :running} = service ->
         Map.put(service, :cleanup_error, {:error, :cleanup_unconfirmed})

       service ->
         service
     end)}
  end

  def handle_info({:EXIT, handle, reason}, state) do
    {:noreply,
     update_service(state, handle, fn
       %{runner: :erlexec, status: :running} = service ->
         Erlexec.finish(service, reason)

       %{status: :running} = service ->
         %{service | status: :exited, exit_status: reason}

       service ->
         service
     end)}
  end

  def handle_info({:timeout, id}, state) do
    case state.services[id] do
      %{status: :running} = service ->
        case state.backend.stop_service(state.backend_state, service) do
          :ok ->
            {:noreply,
             put_in(state.services[id], %{service | status: :timed_out, exit_status: 124})}

          error ->
            {:noreply, record_cleanup_error(state, id, service, error)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_monitor: ref} = state) do
    release_owner_resources(state)
  end

  def handle_info(:release_owner_resources, state), do: release_owner_resources(state)

  def handle_info(_, state), do: {:noreply, state}
  def terminate(:normal, {:failed_open, _}), do: :ok
  def terminate(_, {:failed_open, root}), do: File.rm_rf(root)
  def terminate(_, state), do: cleanup(state)

  defp release_owner_resources(state) do
    with :ok <- release(state) do
      {:stop, :normal, %{state | services: %{}, upload: nil}}
    else
      _ ->
        Registry.unregister(@registry, state.sandbox.id)
        Process.send_after(self(), :release_owner_resources, @release_retry_ms)
        {:noreply, state}
    end
  end

  defp release(state) do
    with :ok <- cleanup(state),
         :ok <- release_root(state.sandbox) do
      Registry.unregister(@registry, state.sandbox.id)
      :ok
    end
  end

  defp release_root(%Sandbox{checkout_key: key}) when not is_nil(key), do: :ok

  defp release_root(%Sandbox{root: root}) do
    case File.rm_rf(root) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp cleanup(state) do
    results =
      Enum.map(state.services, fn {_, service} ->
        state.backend.stop_service(state.backend_state, service)
      end)

    result = with :ok <- discard_upload(state), do: state.backend.destroy(state.backend_state)
    Enum.find(results ++ [result], :ok, &(&1 != :ok))
  end

  defp finish_upload(state, result) do
    case discard_upload(state) do
      :ok -> {:reply, result, %{state | upload: nil}}
      {:error, _} -> {:reply, {:error, :quiescence_unknown}, state}
    end
  end

  defp discard_upload(%{upload: nil}), do: :ok

  defp discard_upload(state) do
    with :ok <- check_checkout(state.sandbox), do: Files.discard_stage(state.upload)
  end

  defp service_info(service) do
    case Map.delete(service, :io_buffer) do
      %{error: {:start_failed, reason}} = info -> %{info | error: reason}
      info -> info
    end
  end

  defp file_view(sandbox, relative) do
    with :ok <- check_checkout(sandbox),
         {:ok, path} <- Files.path(sandbox.root, relative),
         {:ok, entries} <- Files.capture(sandbox.root, relative, true) do
      {:ok,
       %FileView{
         kind: :sandbox,
         owner: sandbox.id,
         path: Path.relative_to(path, sandbox.root),
         revision: FileView.digest(entries)
       }}
    end
  end

  defp check_checkout(sandbox), do: Files.check_checkout(sandbox.root, sandbox.checkout_key)

  defp stop_service(id, state) do
    case state.services[id] do
      nil ->
        {:reply, {:error, :service_not_found}, state}

      %{status: status} = service
      when status == :running or
             (status == :failed and state.sandbox.provider == :apple_container) ->
        case state.backend.stop_service(state.backend_state, service) do
          :ok ->
            stopped = %{service | status: :stopped} |> Map.drop([:error, :cleanup_error])
            {:reply, :ok, put_in(state.services[id], stopped)}

          {:error, :quiescence_unknown} = error ->
            {:reply, error, record_cleanup_error(state, id, service, error)}

          error ->
            {:reply, error, state}
        end

      _service ->
        {:reply, :ok, state}
    end
  end

  defp record_cleanup_error(state, id, service, error) do
    put_in(state.services[id], Map.put(service, :cleanup_error, error))
    |> fence_unconfirmed_apple_service()
  end

  defp fence_unconfirmed_apple_service(%{sandbox: %{provider: :apple_container}} = state) do
    if Enum.any?(state.services, fn {_, service} ->
         service[:error] == :quiescence_unknown or
           service[:cleanup_error] == {:error, :quiescence_unknown}
       end),
       do: Map.put(state, :fence, :quiescence_unknown),
       else: state
  end

  defp fence_unconfirmed_apple_service(state), do: state

  defp require_capability(state, capability) do
    if Map.get(state.capabilities, capability, false),
      do: :ok,
      else: {:error, {:unsupported_capability, capability}}
  end

  defp admit_stdin(%{stdin: :pipe}, %{kind: :exec, stdin: :pipe}, buffer)
       when is_reference(buffer),
       do: :ok

  defp admit_stdin(_, %{stdin: :pipe}, _), do: {:error, {:unsupported_capability, :stdin}}
  defp admit_stdin(_, _, _), do: :ok

  defp valid_spec?(spec) when is_map(spec) do
    kind = Map.get(spec, :kind)
    args = Map.get(spec, :args, [])
    env = Map.get(spec, :env, [])
    timeout = Map.get(spec, :timeout)
    limit = Map.get(spec, :output_limit, 65_536)

    kind in [:beam, :exec] and is_list(args) and Enum.all?(args, &is_binary/1) and
      is_binary(Map.get(spec, :dir, ".")) and is_list(env) and
      Enum.all?(env, fn entry ->
        match?({key, value} when is_binary(key) and is_binary(value), entry)
      end) and
      (timeout == nil or (is_integer(timeout) and timeout > 0)) and
      is_integer(limit) and limit >= 0 and
      (kind == :beam or
         (is_binary(Map.get(spec, :executable)) and Map.get(spec, :executable) != ""))
  end

  defp valid_spec?(_), do: false

  defp update_service(state, handle, fun) do
    %{
      state
      | services:
          Map.new(state.services, fn {id, service} ->
            {id, if(service.handle == handle, do: fun.(service), else: service)}
          end)
    }
  end
end
