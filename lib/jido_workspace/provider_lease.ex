defmodule Jido.Workspace.ProviderLease do
  @moduledoc false

  use GenServer, restart: :temporary, shutdown: 60_000

  alias Jido.Workspace.Provider

  @retry_ms 1_000

  def start({module, options}, scope) do
    lease = %{
      id: "lease-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
      workspace_id: scope.id,
      controller: self(),
      infrastructure: scope.infrastructure
    }

    args = {lease, module, options, scope}

    case DynamicSupervisor.start_child(__MODULE__.Supervisor, {__MODULE__, args}) do
      {:ok, pid} -> {:ok, {pid, scope.confirmation}, lease}
      {:error, _} -> {:error, :operation_failed}
    end
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def confirm({pid, _}, deadline) do
    GenServer.call(pid, :confirm, max(0, deadline - now()))
  catch
    :exit, _ -> {:error, :open_timeout}
  end

  def release({pid, confirmation}) do
    GenServer.call(pid, :release, :infinity)
  catch
    :exit, _ ->
      if :atomics.get(confirmation, 1) == 1, do: :ok, else: {:error, :cleanup_unconfirmed}
  end

  def available?({pid, _}), do: Process.alive?(pid)

  @impl true
  def init({lease, module, options, %{deadline: deadline} = scope}) do
    timer = Process.send_after(self(), :expire, max(0, deadline - now()))
    opening = [scope.owner, scope.opener] |> Enum.uniq() |> Enum.map(&Process.monitor/1)

    {:ok,
     %{
       lease: lease,
       module: module,
       options: options,
       deadline: deadline,
       timer: timer,
       controller: Process.monitor(lease.controller),
       opening: opening,
       confirmation: scope.confirmation,
       retry: nil,
       revoked: false
     }}
  end

  @impl true
  def format_status(status), do: Map.update(status, :state, :redacted, fn _ -> :redacted end)

  @impl true
  def handle_call(:confirm, _, %{revoked: false, deadline: deadline} = state)
      when is_integer(deadline) do
    if now() < deadline do
      Process.cancel_timer(state.timer)
      Enum.each(state.opening, &Process.demonitor(&1, [:flush]))
      {:reply, :ok, %{state | deadline: nil, timer: nil, opening: []}}
    else
      {:reply, {:error, :open_timeout}, state}
    end
  end

  def handle_call(:confirm, _, state), do: {:reply, {:error, :open_timeout}, state}
  def handle_call(:release, from, state), do: revoke(state, from)

  @impl true
  def handle_info(:expire, %{deadline: deadline} = state) when is_integer(deadline),
    do: revoke(state, nil)

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    if ref == state.controller or ref in state.opening,
      do: revoke(state, nil),
      else: {:noreply, state}
  end

  def handle_info(:retry, state), do: revoke(%{state | retry: nil}, nil)
  def handle_info(_, state), do: {:noreply, state}

  defp revoke(state, from) do
    case Provider.call(state.module, :release, [state.lease, state.options], :cleanup_unconfirmed) do
      :ok ->
        :atomics.put(state.confirmation, 1, 1)
        if from, do: GenServer.reply(from, :ok)
        {:stop, :normal, state}

      _ ->
        if from, do: GenServer.reply(from, {:error, :cleanup_unconfirmed})
        retry = state.retry || Process.send_after(self(), :retry, @retry_ms)
        {:noreply, %{state | revoked: true, retry: retry}}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
