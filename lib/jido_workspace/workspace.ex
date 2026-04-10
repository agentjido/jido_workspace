defmodule Jido.Workspace.Workspace do
  @moduledoc """
  Core workspace struct and operations.

  A workspace binds a `workspace_id` to mounted VFS backends through `Jido.Shell.VFS`
  and optionally tracks an active shell session for command execution.
  """

  alias Jido.Shell.Agent, as: ShellAgent
  alias Jido.Shell.Error, as: ShellError
  alias Jido.Shell.ShellSession
  alias Jido.Workspace.Schemas

  @default_root_mount "/"
  @default_adapter Jido.VFS.Adapter.InMemory

  @type snapshot :: %{
          directories: [String.t()],
          files: %{String.t() => binary()}
        }

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t() | nil,
          snapshots: %{String.t() => snapshot()},
          next_snapshot_id: non_neg_integer()
        }

  defstruct [:id, :session_id, snapshots: %{}, next_snapshot_id: 0]

  @doc """
  Creates and mounts a new workspace.

  ## Options

  - `:id` - workspace identifier (default: generated)
  - `:adapter` - `Jido.VFS` adapter module for root mount (default: in-memory)
  - `:adapter_opts` - options passed to adapter configure/mount
  - `:start_session` - whether to start a shell session immediately (default: `false`)
  - `:session_opts` - options forwarded to `Jido.Shell.ShellSession.start/2`
  """
  @spec new(keyword()) :: t() | {:error, term()}
  def new(opts \\ []) do
    workspace_id = Keyword.get_lazy(opts, :id, &default_workspace_id/0)
    adapter = Keyword.get(opts, :adapter, @default_adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    with :ok <- ensure_dependencies_started(),
         {:ok, workspace_id} <- Schemas.validate_workspace_id(workspace_id),
         :ok <- mount_root(workspace_id, adapter, adapter_opts) do
      workspace = %__MODULE__{id: workspace_id}

      if Keyword.get(opts, :start_session, false) do
        session_opts = Keyword.get(opts, :session_opts, [])

        case start_session(workspace, session_opts) do
          {:ok, started_workspace} -> started_workspace
          {:error, reason} -> {:error, reason}
        end
      else
        workspace
      end
    end
  end

  @doc """
  Returns the workspace id.
  """
  @spec workspace_id(t()) :: String.t()
  def workspace_id(%__MODULE__{id: id}), do: id

  @doc """
  Returns the active session id (if present).
  """
  @spec session_id(t()) :: String.t() | nil
  def session_id(%__MODULE__{session_id: session_id}), do: session_id

  @doc """
  Writes content to an artifact path.
  """
  @spec write(t(), String.t(), iodata()) :: {:ok, t()} | {:error, term()}
  def write(%__MODULE__{} = workspace, path, content) do
    with {:ok, path} <- Schemas.validate_path(path),
         :ok <- Jido.Shell.VFS.write_file(workspace.id, path, IO.iodata_to_binary(content)) do
      {:ok, workspace}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc """
  Reads content from an artifact path.
  """
  @spec read(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(%__MODULE__{} = workspace, path) do
    with {:ok, path} <- Schemas.validate_path(path),
         {:ok, content} <- Jido.Shell.VFS.read_file(workspace.id, path) do
      {:ok, content}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc """
  Lists names under a directory path.
  """
  @spec list(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(%__MODULE__{} = workspace, path \\ "/") do
    with {:ok, path} <- Schemas.validate_path(path),
         {:ok, entries} <- Jido.Shell.VFS.list_dir(workspace.id, path) do
      {:ok, entries |> Enum.map(& &1.name) |> Enum.sort()}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc """
  Deletes a file or directory path.
  """
  @spec delete(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def delete(%__MODULE__{} = workspace, path) do
    with {:ok, path} <- Schemas.validate_path(path),
         :ok <- Jido.Shell.VFS.delete(workspace.id, path) do
      {:ok, workspace}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc """
  Creates a directory path.
  """
  @spec mkdir(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def mkdir(%__MODULE__{} = workspace, path) do
    with {:ok, path} <- Schemas.validate_path(path),
         :ok <- Jido.Shell.VFS.mkdir(workspace.id, path) do
      {:ok, workspace}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc """
  Captures a snapshot of the current workspace tree.
  """
  @spec snapshot(t()) :: {:ok, String.t(), t()} | {:error, term()}
  def snapshot(%__MODULE__{} = workspace) do
    with {:ok, snapshot} <- capture_snapshot(workspace) do
      snapshot_id = "snap-#{workspace.next_snapshot_id}"

      updated_workspace =
        workspace
        |> put_in([Access.key(:snapshots), snapshot_id], snapshot)
        |> update_in([Access.key(:next_snapshot_id)], &(&1 + 1))

      {:ok, snapshot_id, updated_workspace}
    end
  end

  @doc """
  Restores the workspace tree from a prior snapshot id.
  """
  @spec restore(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def restore(%__MODULE__{} = workspace, snapshot_id) do
    case Map.fetch(workspace.snapshots, snapshot_id) do
      {:ok, snapshot} ->
        with :ok <- clear_workspace(workspace),
             :ok <- apply_snapshot(workspace, snapshot) do
          {:ok, workspace}
        else
          {:error, reason} -> {:error, normalize_error(reason)}
        end

      :error ->
        {:error, :unknown_snapshot}
    end
  end

  @doc """
  Starts a shell session for the workspace.
  """
  @spec start_session(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start_session(%__MODULE__{} = workspace, opts \\ []) do
    if session_active?(workspace.session_id) do
      {:ok, workspace}
    else
      with {:ok, session_id} <- ShellSession.start(workspace.id, opts) do
        {:ok, %{workspace | session_id: session_id}}
      else
        {:error, reason} -> {:error, normalize_error(reason)}
      end
    end
  end

  @doc """
  Runs a shell command in the workspace session.

  Starts a session automatically if needed.
  """
  @spec run(t(), String.t(), keyword()) :: {:ok, binary(), t()} | {:error, term(), t()}
  def run(%__MODULE__{} = workspace, command, opts \\ []) do
    with {:ok, command} <- Schemas.validate_command(command),
         {:ok, active_workspace} <- ensure_session(workspace) do
      case ShellAgent.run(active_workspace.session_id, command, opts) do
        {:ok, output} -> {:ok, output, active_workspace}
        {:error, reason} -> {:error, normalize_error(reason), active_workspace}
      end
    else
      {:error, reason} -> {:error, normalize_error(reason), workspace}
    end
  end

  @doc """
  Stops the active workspace session if present.
  """
  @spec stop_session(t()) :: {:ok, t()}
  def stop_session(%__MODULE__{session_id: nil} = workspace), do: {:ok, workspace}

  def stop_session(%__MODULE__{} = workspace) do
    case ShellAgent.stop(workspace.session_id) do
      :ok -> {:ok, %{workspace | session_id: nil}}
      {:error, :not_found} -> {:ok, %{workspace | session_id: nil}}
    end
  end

  @doc """
  Stops session and unmounts all mounted filesystems for this workspace.
  """
  @spec close(t()) :: {:ok, t()} | {:error, term()}
  def close(%__MODULE__{} = workspace) do
    with {:ok, stopped_workspace} <- stop_session(workspace),
         :ok <- unmount_workspace(stopped_workspace.id) do
      {:ok, stopped_workspace}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp ensure_session(%__MODULE__{} = workspace) do
    if session_active?(workspace.session_id) do
      {:ok, workspace}
    else
      start_session(workspace)
    end
  end

  defp session_active?(nil), do: false

  defp session_active?(session_id) do
    case ShellSession.lookup(session_id) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
    end
  end

  defp capture_snapshot(workspace) do
    case capture_directory(workspace, @default_root_mount, [@default_root_mount], %{}) do
      {:ok, {directories, files}} ->
        {:ok,
         %{
           directories:
             directories
             |> Enum.uniq()
             |> Enum.sort_by(&String.length/1),
           files: files
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_directory(workspace, path, directories, files) do
    with {:ok, entries} <- Jido.Shell.VFS.list_dir(workspace.id, path) do
      Enum.reduce_while(entries, {:ok, {directories, files}}, fn entry, {:ok, {dirs, file_map}} ->
        child_path = join_path(path, entry.name)

        cond do
          match?(%Jido.VFS.Stat.Dir{}, entry) ->
            case capture_directory(workspace, child_path, [child_path | dirs], file_map) do
              {:ok, {new_dirs, new_file_map}} -> {:cont, {:ok, {new_dirs, new_file_map}}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          match?(%Jido.VFS.Stat.File{}, entry) ->
            case read(workspace, child_path) do
              {:ok, content} -> {:cont, {:ok, {dirs, Map.put(file_map, child_path, content)}}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          true ->
            {:cont, {:ok, {dirs, file_map}}}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_workspace(workspace) do
    clear_directory(workspace, @default_root_mount)
  end

  defp clear_directory(workspace, path) do
    with {:ok, entries} <- Jido.Shell.VFS.list_dir(workspace.id, path) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        child_path = join_path(path, entry.name)

        case delete_entry(workspace, entry, child_path) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_entry(workspace, %Jido.VFS.Stat.Dir{}, path) do
    with :ok <- clear_directory(workspace, path),
         :ok <- Jido.Shell.VFS.delete(workspace.id, path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_entry(workspace, %Jido.VFS.Stat.File{}, path) do
    case Jido.Shell.VFS.delete(workspace.id, path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_entry(_workspace, _entry, _path), do: :ok

  defp apply_snapshot(workspace, snapshot) do
    with :ok <- restore_directories(workspace, snapshot.directories),
         :ok <- restore_files(workspace, snapshot.files) do
      :ok
    end
  end

  defp restore_directories(workspace, directories) do
    directories
    |> Enum.uniq()
    |> Enum.reject(&(&1 == @default_root_mount))
    |> Enum.sort_by(&String.length/1)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case Jido.Shell.VFS.mkdir(workspace.id, path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp restore_files(workspace, files) do
    files
    |> Enum.sort_by(fn {path, _content} -> String.length(path) end)
    |> Enum.reduce_while(:ok, fn {path, content}, :ok ->
      case Jido.Shell.VFS.write_file(workspace.id, path, content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mount_root(workspace_id, adapter, adapter_opts) do
    mount_opts =
      adapter_opts
      |> maybe_put_in_memory_name(workspace_id, adapter)
      |> Keyword.put_new(:managed, true)

    case Jido.Shell.VFS.mount(workspace_id, @default_root_mount, adapter, mount_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp maybe_put_in_memory_name(opts, workspace_id, Jido.VFS.Adapter.InMemory) do
    Keyword.put_new(opts, :name, default_filesystem_name(workspace_id))
  end

  defp maybe_put_in_memory_name(opts, _workspace_id, _adapter), do: opts

  defp ensure_dependencies_started do
    with :ok <- ensure_started(:jido_vfs),
         :ok <- ensure_started(:jido_shell) do
      :ok
    end
  end

  defp ensure_started(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, {failed_app, reason}} -> {:error, {:app_start_failed, failed_app, reason}}
    end
  end

  defp unmount_workspace(workspace_id) do
    case Jido.Shell.VFS.unmount_workspace(workspace_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp join_path("/", name), do: "/" <> name
  defp join_path(path, name), do: path <> "/" <> name

  defp normalize_error(%ShellError{code: {:vfs, :not_found}}), do: :file_not_found
  defp normalize_error(%ShellError{code: {:vfs, :already_exists}}), do: :already_exists
  defp normalize_error(%ShellError{code: {:vfs, :directory_not_empty}}), do: :directory_not_empty
  defp normalize_error(%ShellError{code: {:vfs, :not_directory}}), do: :not_directory
  defp normalize_error(%ShellError{code: {:vfs, :path_traversal}}), do: :path_traversal
  defp normalize_error(%ShellError{code: {:vfs, :no_mount}}), do: :workspace_not_mounted
  defp normalize_error(%ShellError{code: {:session, :invalid_workspace_id}}), do: :invalid_workspace_id
  defp normalize_error(%ShellError{code: {:command, :timeout}}), do: :command_timeout
  defp normalize_error(%ShellError{code: {:command, :cancelled}}), do: :command_cancelled
  defp normalize_error(%ShellError{} = error), do: error
  defp normalize_error(other), do: other

  defp default_workspace_id do
    "workspace-#{System.unique_integer([:positive])}"
  end

  defp default_filesystem_name(workspace_id) do
    safe_workspace =
      workspace_id
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
      |> String.slice(0, 48)

    "jido_workspace_fs_#{safe_workspace}_#{System.unique_integer([:positive])}"
  end
end
