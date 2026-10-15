defmodule Jido.Workspace.Workspace do
  @moduledoc """
  Core workspace struct and operations.

  A workspace binds a `workspace_id` to mounted VFS backends through `Jido.Shell.VFS`
  and optionally tracks an active shell session for command execution.
  """

  alias Jido.Shell.Agent, as: ShellAgent
  alias Jido.Shell.Error, as: ShellError
  alias Jido.Workspace.Schemas

  alias Jido.Workspace.Lifetime
  @type t :: %__MODULE__{id: String.t(), lifetime: pid(), session_id: String.t() | nil}
  defstruct [:id, :lifetime, :session_id]

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
    opts = Keyword.put_new(opts, :owner, self())

    with :ok <- ensure_dependencies_started(),
         {:ok, id} <- Schemas.validate_workspace_id(workspace_id),
         {:ok, lifetime} <- Lifetime.start(id, opts) do
      %__MODULE__{id: id, lifetime: lifetime, session_id: Lifetime.call(lifetime, :session_id)}
    end
  end

  @doc "Opens an owned workspace. The default storage is in memory."
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    case new(opts) do
      %__MODULE__{} = workspace -> {:ok, workspace}
      error -> error
    end
  end

  @doc "Returns the public VFS handle for the owned root filesystem."
  @spec filesystem(t()) :: {:ok, Jido.VFS.filesystem()} | {:error, term()}
  def filesystem(workspace), do: Lifetime.call(workspace.lifetime, :filesystem)

  @doc "Starts or returns the owned shell session."
  @spec shell(t()) :: {:ok, String.t()} | {:error, term()}
  def shell(workspace), do: Lifetime.call(workspace.lifetime, {:shell, []})

  @doc "Captures the owned root filesystem atomically. Multiple mounts are refused."
  @spec capture(t()) :: {:ok, Jido.VFS.Capture.t(), term()} | {:error, term()}
  def capture(workspace) do
    with :ok <- single_mount(workspace), {:ok, fs} <- filesystem(workspace), do: Jido.VFS.capture(fs)
  end

  @doc "Replaces content only at the expected storage state."
  @spec replace(t(), term(), Jido.VFS.Capture.t()) :: {:ok, term()} | {:error, term()}
  def replace(workspace, token, capture) do
    with :ok <- single_mount(workspace), {:ok, fs} <- filesystem(workspace), do: Jido.VFS.replace(fs, token, capture)
  end

  defp single_mount(workspace) do
    case Jido.Shell.VFS.list_mounts(workspace.id) do
      [%{path: "/"}] -> :ok
      [] -> {:error, :closed}
      _ -> {:error, :multiple_mounts}
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
  def session_id(workspace), do: Lifetime.call(workspace.lifetime, :session_id)

  @doc """
  Writes content to an artifact path.
  """
  @spec write(t(), String.t(), iodata()) :: {:ok, t()} | {:error, term()}
  def write(%__MODULE__{} = workspace, path, content) do
    with {:ok, path} <- Schemas.validate_path(path),
         :ok <- Lifetime.call(workspace.lifetime, {:file, :write_file, [path, IO.iodata_to_binary(content)]}) do
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
         {:ok, content} <- Lifetime.call(workspace.lifetime, {:file, :read_file, [path]}) do
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
         {:ok, entries} <- Lifetime.call(workspace.lifetime, {:file, :list_dir, [path]}) do
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
         :ok <- Lifetime.call(workspace.lifetime, {:file, :delete, [path]}) do
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
         :ok <- Lifetime.call(workspace.lifetime, {:file, :mkdir, [path]}) do
      {:ok, workspace}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc """
  Captures a snapshot of the current workspace tree.
  """
  @spec snapshot(t()) :: {:ok, Jido.VFS.Capture.t(), t()} | {:error, term()}
  def snapshot(workspace) do
    case capture(workspace) do
      {:ok, capture, _token} -> {:ok, capture, workspace}
      error -> error
    end
  end

  @doc """
  Restores the workspace tree from a prior immutable capture.
  """
  @spec restore(t(), Jido.VFS.Capture.t()) :: {:ok, t()} | {:error, term()}
  def restore(workspace, %Jido.VFS.Capture{} = saved) do
    with {:ok, _current, token} <- capture(workspace),
         {:ok, _} <- replace(workspace, token, saved),
         do: {:ok, workspace}
  end

  def restore(_workspace, _), do: {:error, :unknown_snapshot}

  @doc """
  Starts a shell session for the workspace.
  """
  @spec start_session(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    case Lifetime.call(workspace.lifetime, {:shell, opts}) do
      {:ok, id} -> {:ok, %{workspace | session_id: id}}
      error -> error
    end
  end

  @doc """
  Runs a shell command in the workspace session.

  Starts a session automatically if needed.
  """
  @spec run(t(), String.t(), keyword()) :: {:ok, binary(), t()} | {:error, term(), t()}
  def run(%__MODULE__{} = workspace, command, opts \\ []) do
    with {:ok, command} <- Schemas.validate_command(command),
         {:ok, id, pid} <- Lifetime.call(workspace.lifetime, :session_pid) do
      active_workspace = %{workspace | session_id: id}

      case ShellAgent.run(pid, command, opts) do
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
  def stop_session(workspace) do
    case Lifetime.call(workspace.lifetime, :stop_session) do
      :ok -> {:ok, %{workspace | session_id: nil}}
      error -> error
    end
  end

  @doc """
  Stops session and unmounts all mounted filesystems for this workspace.
  """
  @spec close(t()) :: {:ok, t()} | {:error, term()}
  def close(workspace) do
    case Lifetime.call(workspace.lifetime, :close) do
      :ok -> {:ok, %{workspace | session_id: nil}}
      {:error, :closed} -> {:ok, %{workspace | session_id: nil}}
      error -> error
    end
  end

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
end
