defmodule Jido.Workspace do
  @moduledoc """
  Unified workspace for agent artifacts and shell sessions.

  `Jido.Workspace` provides a single struct that owns:

  - Files/artifacts in a mounted `Jido.VFS` filesystem
  - Optional shell session state for command execution in that workspace
  - Immutable VFS captures for save/restore workflows during an agent run

  The default setup mounts an in-memory VFS at `/` via `Jido.Shell.VFS`.
  """

  alias Jido.Workspace.Workspace

  @type t :: Workspace.t()

  @doc "Opens an owned working environment with memory storage by default."
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  defdelegate open(opts \\ []), to: Workspace

  @doc "Returns the owned root filesystem handle."
  @spec filesystem(t()) :: {:ok, Jido.VFS.filesystem()} | {:error, term()}
  defdelegate filesystem(workspace), to: Workspace

  @doc "Starts or returns the owned shell session."
  @spec shell(t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate shell(workspace), to: Workspace

  @doc "Captures immutable content and a concurrency token."
  @spec capture(t()) :: {:ok, Jido.VFS.Capture.t(), term()} | {:error, term()}
  defdelegate capture(workspace), to: Workspace

  @doc "Replaces working content only at the expected token."
  @spec replace(t(), term(), Jido.VFS.Capture.t()) :: {:ok, term()} | {:error, term()}
  defdelegate replace(workspace, token, capture), to: Workspace

  @doc """
  Creates and mounts a new workspace.
  """
  @spec new(keyword()) :: t() | {:error, term()}
  defdelegate new(opts \\ []), to: Workspace

  @doc """
  Returns the workspace identifier.
  """
  @spec workspace_id(t()) :: String.t()
  defdelegate workspace_id(workspace), to: Workspace

  @doc """
  Returns the active shell session id, if present.
  """
  @spec session_id(t()) :: String.t() | nil
  defdelegate session_id(workspace), to: Workspace

  @doc """
  Writes artifact content to an absolute path in the workspace.
  """
  @spec write(t(), String.t(), iodata()) :: {:ok, t()} | {:error, term()}
  defdelegate write(workspace, path, content), to: Workspace

  @doc """
  Reads artifact content from an absolute path.
  """
  @spec read(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  defdelegate read(workspace, path), to: Workspace

  @doc """
  Lists entries under an absolute directory path.
  """
  @spec list(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate list(workspace, path \\ "/"), to: Workspace

  @doc """
  Deletes an artifact path.
  """
  @spec delete(t(), String.t()) :: {:ok, t()} | {:error, term()}
  defdelegate delete(workspace, path), to: Workspace

  @doc """
  Creates a directory path.
  """
  @spec mkdir(t(), String.t()) :: {:ok, t()} | {:error, term()}
  defdelegate mkdir(workspace, path), to: Workspace

  @doc """
  Captures an immutable VFS tree. Unsupported backends return an error.
  """
  @spec snapshot(t()) :: {:ok, Jido.VFS.Capture.t(), t()} | {:error, term()}
  defdelegate snapshot(workspace), to: Workspace

  @doc """
  Restores a previously captured filesystem.
  """
  @spec restore(t(), Jido.VFS.Capture.t()) :: {:ok, t()} | {:error, term()}
  defdelegate restore(workspace, capture), to: Workspace

  @doc """
  Starts a shell session bound to this workspace.
  """
  @spec start_session(t(), keyword()) :: {:ok, t()} | {:error, term()}
  defdelegate start_session(workspace, opts \\ []), to: Workspace

  @doc """
  Runs a shell command in the workspace session.

  If no session exists, one is started automatically.
  """
  @spec run(t(), String.t(), keyword()) :: {:ok, binary(), t()} | {:error, term(), t()}
  defdelegate run(workspace, command, opts \\ []), to: Workspace

  @doc """
  Stops the active shell session, if present.
  """
  @spec stop_session(t()) :: {:ok, t()} | {:error, term()}
  defdelegate stop_session(workspace), to: Workspace

  @doc """
  Stops the shell session and unmounts workspace filesystems.
  """
  @spec close(t()) :: {:ok, t()} | {:error, term()}
  defdelegate close(workspace), to: Workspace
end
