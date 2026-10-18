defmodule Jido.Workspace.Lifetime do
  @moduledoc false
  use GenServer
  alias Jido.Shell.{ShellSession, VFS}
  alias Jido.Workspace.FileView

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

    with :ok <- Jido.Workspace.Policy.validate(Keyword.get(opts, :policy, :full_access)),
         {:ok, fs} <- Jido.VFS.safe_configure(adapter, adapter_opts),
         {:ok, storage} <- start_storage(adapter, fs) do
      state = %{
        id: id,
        fs: fs,
        storage: storage,
        owner: monitor,
        owner_pid: owner,
        session_opts: Keyword.get(opts, :session_opts, []),
        session: nil,
        session_pid: nil,
        policy: Keyword.get(opts, :policy, :full_access)
      }

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
  def handle_call(:info, _, state) do
    info = %Jido.Workspace.Info{
      id: state.id,
      policy: state.policy,
      owner: state.owner_pid,
      session:
        if(state.session_pid && Process.alive?(state.session_pid), do: :running, else: :stopped)
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:file_view, _, state), do: {:reply, observed_files(state), state}

  def handle_call({:command_session, expected}, _, state) do
    with :ok <- authorize(state, :execute),
         {:ok, next} <- ensure_session(state, []) do
      result =
        with {:ok, view} <- observed_files(next),
             :ok <- FileView.check(expected, view),
             do: {:ok, next.session, next.session_pid, view}

      {:reply, result, next}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:filesystem, _, state) do
    result = with :ok <- authorize(state, :raw_handle), do: {:ok, state.fs}
    {:reply, result, state}
  end

  def handle_call(:capture, _, state) do
    result = with :ok <- single_mount(state), do: Jido.VFS.capture(state.fs)
    {:reply, result, state}
  end

  def handle_call({:replace, token, capture}, _, state) do
    result =
      with :ok <- authorize(state, :write),
           :ok <- single_mount(state),
           do: Jido.VFS.replace(state.fs, token, capture)

    {:reply, result, state}
  end

  def handle_call({:file, operation, args}, _, state) do
    action = if operation in [:read_file, :list_dir], do: :read, else: :write
    result = with :ok <- authorize(state, action), do: apply(VFS, operation, [state.id | args])
    {:reply, result, state}
  end

  def handle_call({:shell, opts}, _, state) do
    case with(:ok <- authorize(state, :raw_handle), do: ensure_session(state, opts)) do
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
  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _}, %{storage: pid} = state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, state), do: cleanup(state)

  defp observed_files(%{session_pid: pid} = state) when is_pid(pid) do
    with {:ok, session} <- Jido.Shell.ShellSessionServer.get_state(pid) do
      case session.backend do
        Jido.Shell.Backend.Local ->
          workspace_files(state, session.workspace_id)

        backend ->
          {:ok,
           %FileView{
             kind: :backend,
             owner: {backend, pid},
             path: :unknown,
             revision: :unavailable
           }}
      end
    end
  end

  defp observed_files(state), do: workspace_files(state, state.id)

  defp workspace_files(state, workspace_id) do
    revision =
      case VFS.list_mounts(workspace_id) do
        [%{path: "/", filesystem: fs}] when fs == state.fs ->
          case Jido.VFS.capture(state.fs) do
            {:ok, _, token} -> token
            _ -> :unavailable
          end

        _ ->
          :unavailable
      end

    {:ok, %FileView{kind: :workspace, owner: self(), path: "/", revision: revision}}
  end

  defp ensure_session(state, opts) do
    if authorize(state, :execute) != :ok do
      {:error, {:policy_denied, :execute}}
    else
      do_ensure_session(state, opts)
    end
  end

  defp authorize(state, action), do: Jido.Workspace.Policy.authorize(state.policy, action)

  defp single_mount(state) do
    case VFS.list_mounts(state.id) do
      [%{path: "/", filesystem: fs}] when fs == state.fs -> :ok
      _ -> {:error, :multiple_mounts}
    end
  end

  defp do_ensure_session(state, opts) do
    if state.session_pid && Process.alive?(state.session_pid) do
      {:ok, state}
    else
      # The lifetime process owns the session. Shell only borrows storage.
      with {:ok, pid} <-
             ShellSession.start_with_filesystem_pid(
               state.fs,
               state.session_opts |> Keyword.merge(opts) |> Keyword.put(:owner, self())
             ),
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
