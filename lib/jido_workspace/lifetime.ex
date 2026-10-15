defmodule Jido.Workspace.Lifetime do
  @moduledoc false
  use GenServer
  alias Jido.Shell.{ShellSession, VFS}

  def start(id, opts), do: GenServer.start(__MODULE__, {id, opts})

  def call(pid, request) do
    GenServer.call(pid, request)
  catch
    :exit, {:noproc, _} -> {:error, :closed}
    :exit, {:normal, _} -> {:error, :closed}
  end

  @impl true
  def init({id, opts}) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    monitor = Process.monitor(owner)
    adapter = Keyword.get(opts, :adapter, Jido.VFS.Adapter.InMemory)
    adapter_opts = Keyword.get(opts, :adapter_opts, []) |> Keyword.put_new(:name, make_ref())

    with {:ok, fs} <- Jido.VFS.safe_configure(adapter, adapter_opts),
         {:ok, storage} <- start_storage(adapter, fs) do
      state = %{id: id, fs: fs, storage: storage, owner: monitor, session: nil, session_pid: nil}

      case VFS.MountTable.attach(id, "/", fs) do
        :ok ->
          :ok = VFS.MountTable.track(id, self())

          if Keyword.get(opts, :start_session, false) do
            case ensure_session(state, Keyword.get(opts, :session_opts, [])) do
              {:ok, next} ->
                {:ok, next}

              {:error, reason} ->
                cleanup(state)
                {:stop, reason}
            end
          else
            {:ok, state}
          end

        {:error, reason} ->
          stop_storage(storage)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:filesystem, _, state), do: {:reply, {:ok, state.fs}, state}
  def handle_call(:session_id, _, state), do: {:reply, state.session, state}

  def handle_call({:file, operation, args}, _, state) do
    {:reply, apply(VFS, operation, [state.id | args]), state}
  end

  def handle_call(:session_pid, _, state) do
    case ensure_session(state, []) do
      {:ok, next} -> {:reply, {:ok, next.session, next.session_pid}, next}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:shell, opts}, _, state) do
    case ensure_session(state, opts) do
      {:ok, next} -> {:reply, {:ok, next.session}, next}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:stop_session, _, state) do
    stop_session(state.session_pid)
    {:reply, :ok, %{state | session: nil, session_pid: nil}}
  end

  def handle_call(:close, _, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state), do: {:stop, :normal, state}
  def handle_info({:EXIT, pid, _}, %{storage: pid} = state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, state), do: cleanup(state)

  defp ensure_session(state, opts) do
    if state.session_pid && Process.alive?(state.session_pid) do
      {:ok, state}
    else
      # The lifetime process owns the session. Shell only borrows storage.
      with {:ok, pid} <- ShellSession.start_with_filesystem_pid(state.fs, Keyword.put(opts, :owner, self())),
           {:ok, session_state} <- Jido.Shell.ShellSessionServer.get_state(pid) do
        {:ok, %{state | session: session_state.id, session_pid: pid}}
      end
    end
  end

  defp start_storage(adapter, fs) do
    if adapter.starts_processes(), do: adapter.start_link(fs), else: {:ok, nil}
  end

  defp cleanup(state) do
    stop_session(state.session_pid)
    VFS.unmount_workspace(state.id)
    stop_storage(state.storage)
  end

  defp stop_session(nil), do: :ok
  defp stop_session(id), do: ShellSession.stop(id)
  defp stop_storage(nil), do: :ok

  defp stop_storage(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
