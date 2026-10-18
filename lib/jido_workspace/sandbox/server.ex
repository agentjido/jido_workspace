defmodule Jido.Workspace.Sandbox.Server do
  @moduledoc false
  use GenServer, restart: :temporary, shutdown: 60_000
  alias Jido.Workspace.FileView
  alias Jido.Workspace.Sandbox
  alias Jido.Workspace.Sandbox.{Files, OTP}

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def init({id, root, policy, backend, opts}) do
    Process.flag(:trap_exit, true)
    sandbox = %Sandbox{id: id, root: root, pid: self()}

    case File.mkdir(root) do
      :ok ->
        case backend.open(sandbox, opts) do
          {:ok, backend_state, capabilities} ->
            sandbox = %{sandbox | provider: capabilities.provider}
            Registry.register(Jido.Workspace.Sandbox.Registry, id, root)

            {:ok,
             %{
               sandbox: sandbox,
               backend: backend,
               backend_state: backend_state,
               capabilities: capabilities,
               services: %{},
               deployments: %{},
               policy: policy,
               case_sensitive: Files.case_sensitive?(root)
             }}

          {:error, reason} ->
            File.rm_rf(root)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, {:root, reason}}
    end
  end

  def handle_call(:handle, _, state), do: {:reply, {:ok, state.sandbox}, state}
  def handle_call(:capabilities, _, state), do: {:reply, state.capabilities, state}

  # Each operation checks the controller and generation in the same server call.
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
      with {:ok, path} <- Files.path(state.sandbox.root, relative) do
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
           do: OTP.prepare(state.sandbox.root, relative, version, initialize)

    {:reply, result, state}
  end

  def handle_call({:files, operation, args}, _, state)
      when operation in [:path, :read, :read_link, :verify, :mkdir, :replace_link] do
    action = if operation in [:mkdir, :replace_link], do: :write, else: :read

    result =
      with :ok <- Jido.Workspace.Policy.authorize(state.policy, action),
           do: apply(Files, operation, [state.sandbox.root | args])

    {:reply, result, state}
  end

  def handle_call({:files, _, _}, _, state),
    do: {:reply, {:error, :unsupported_file_operation}, state}

  def handle_call({:write, relative, bytes, mode}, _, state) do
    result =
      with :ok <- Jido.Workspace.Policy.authorize(state.policy, :write),
           do: Files.write(state.sandbox.root, relative, bytes, mode)

    {:reply, result, state}
  end

  def handle_call(:info, _, state),
    do: {:reply, {:ok, %{sandbox: state.sandbox, services: state.services}}, state}

  def handle_call({:start_service, spec}, _, state) do
    result =
      with :ok <- Jido.Workspace.Policy.authorize(state.policy, :execute) do
        with true <- valid_spec?(spec),
             :ok <- require_capability(state, if(spec.kind == :beam, do: :beam_call, else: :exec)),
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

        if timeout = Map.get(spec, :timeout),
          do: Process.send_after(self(), {:timeout, id}, timeout)

        {:reply, {:ok, id}, put_in(state.services[id], service)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:service_status, id}, _, state) do
    result =
      case Map.fetch(state.services, id) do
        {:ok, %{error: error}} -> {:error, error}
        {:ok, service} -> {:ok, Map.drop(service, [:handle])}
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
    with :ok <- cleanup(state),
         {:ok, _} <- File.rm_rf(state.sandbox.root) do
      Registry.unregister(Jido.Workspace.Sandbox.Registry, state.sandbox.id)
      {:stop, :normal, :ok, %{state | services: %{}}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_info({port, {:data, bytes}}, state) do
    {:noreply,
     update_service(state, port, fn service ->
       remaining = max(service.output_limit - byte_size(service.output), 0)

       %{
         service
         | output: service.output <> binary_part(bytes, 0, min(byte_size(bytes), remaining)),
           truncated: service.truncated or byte_size(bytes) > remaining
       }
     end)}
  end

  def handle_info({port, {:exit_status, code}}, state) do
    {:noreply,
     update_service(state, port, fn service ->
       if service.status == :running do
         case state.backend.finish_service(state.backend_state, service, code) do
           {:ok, service} -> service
           {:error, error} -> Map.merge(service, %{status: :failed, error: error})
         end
       else
         service
       end
     end)}
  end

  def handle_info({:EXIT, handle, reason}, state) do
    {:noreply,
     update_service(state, handle, fn service ->
       if service.status == :running,
         do: %{service | status: :exited, exit_status: reason},
         else: service
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
            {:noreply, put_in(state.services[id], Map.put(service, :cleanup_error, error))}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}
  def terminate(_, state), do: cleanup(state)

  defp cleanup(state) do
    results =
      Enum.map(state.services, fn {_, service} ->
        state.backend.stop_service(state.backend_state, service)
      end)

    result = state.backend.destroy(state.backend_state)
    Enum.find(results ++ [result], :ok, &(&1 != :ok))
  end

  defp file_view(sandbox, relative) do
    with {:ok, path} <- Files.path(sandbox.root, relative),
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

  defp stop_service(id, state) do
    case state.services[id] do
      nil ->
        {:reply, {:error, :service_not_found}, state}

      %{status: :running} = service ->
        case state.backend.stop_service(state.backend_state, service) do
          :ok -> {:reply, :ok, put_in(state.services[id], %{service | status: :stopped})}
          error -> {:reply, error, state}
        end

      _service ->
        {:reply, :ok, state}
    end
  end

  defp require_capability(state, capability) do
    if Map.get(state.capabilities, capability, false),
      do: :ok,
      else: {:error, {:unsupported_capability, capability}}
  end

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
