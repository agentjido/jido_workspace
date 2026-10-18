defmodule Jido.Workspace do
  @moduledoc """
  Working files, immutable captures, and virtual Shell commands.

  Keep the same handle for the resource lifetime. The controller owns storage,
  policy, and session state. File changes and session stop return `:ok`.
  All failures return `Jido.Workspace.Error`.
  """
  alias Jido.Workspace.{Entry, Error, Execution, Info, Lifetime, Schemas, Workspace}
  @type t :: Workspace.t()
  @type mutation_result :: :ok | {:error, Error.t()}

  @doc "Opens a workspace. The caller owns it unless the host supplies `:owner`."
  @spec open(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(opts \\ []) do
    with :ok <- open_options(opts),
         {:ok, id} <- Schemas.validate_workspace_id(Keyword.get_lazy(opts, :id, &unique_id/0)),
         {:ok, _} <- Application.ensure_all_started(:jido_shell),
         {:ok, lifetime} <- Lifetime.start(id, Keyword.put_new(opts, :owner, self())) do
      {:ok, %Workspace{id: id, lifetime: lifetime}}
    else
      {:error, reason} -> error(:open, nil, reason)
    end
  end

  @doc "Returns current identity, policy, owner, and session status."
  @spec info(t()) :: {:ok, Info.t()} | {:error, Error.t()}
  def info(ws), do: call(ws, :info, :info)

  @doc "Returns the root VFS handle. Requires raw-handle permission."
  @spec filesystem(t()) :: {:ok, Jido.VFS.filesystem()} | {:error, Error.t()}
  def filesystem(ws), do: call(ws, :filesystem, :filesystem)

  @doc "Starts or returns the Shell session ID. Requires raw-handle permission."
  @spec shell(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def shell(ws), do: call(ws, {:shell, []}, :shell)

  @doc "Starts or returns the session. Options apply only when it starts."
  @spec start_session(t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def start_session(ws, opts \\ []) do
    if Keyword.keyword?(opts),
      do: call(ws, {:shell, opts}, :start_session),
      else: error(:start_session, ws.id, :invalid_input)
  end

  @doc "Stops the session. The Workspace and its files remain open."
  @spec stop_session(t()) :: mutation_result()
  def stop_session(ws), do: call(ws, :stop_session, :stop_session)

  @doc "Reads file bytes at an absolute path."
  @spec read(t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read(ws, path), do: file(ws, path, :read, :read_file, [])

  @doc "Writes iodata at an absolute path."
  @spec write(t(), String.t(), iodata()) :: mutation_result()
  def write(ws, path, content) do
    with {:ok, bytes} <- bytes(content) do
      file(ws, path, :write, :write_file, [bytes])
    else
      {:error, reason} -> error(:write, ws.id, reason)
    end
  end

  @doc "Creates a directory at an absolute path."
  @spec mkdir(t(), String.t()) :: mutation_result()
  def mkdir(ws, path), do: file(ws, path, :mkdir, :mkdir, [])

  @doc "Deletes a file or an empty directory at an absolute path."
  @spec delete(t(), String.t()) :: mutation_result()
  def delete(ws, path), do: file(ws, path, :delete, :delete, [])

  @doc "Lists entries in path order. Unknown metadata is nil."
  @spec list(t(), String.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def list(ws, path \\ "/") do
    with {:ok, path} <- validate_path(path),
         {:ok, entries} <- call(ws, {:file, :list_dir, [path]}, :list) do
      {:ok,
       entries
       |> Enum.map(fn entry ->
         %Entry{
           path: Path.join(path, entry.name),
           kind: if(is_struct(entry, Jido.VFS.Stat.Dir), do: :directory, else: :file),
           mode: Map.get(entry, :mode),
           size: entry.size
         }
       end)
       |> Enum.sort_by(& &1.path)}
    else
      {:error, %Error{} = reason} -> {:error, reason}
      {:error, reason} -> error(:list, ws.id, reason)
    end
  end

  @doc "Captures immutable content and a revision. Multiple mounts are refused."
  @spec capture(t()) :: {:ok, Jido.VFS.Capture.t(), term()} | {:error, Error.t()}
  def capture(ws), do: call(ws, :capture, :capture)

  @doc "Replaces files only when the expected revision still identifies current content."
  @spec replace(t(), Jido.VFS.Capture.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def replace(ws, capture, opts) do
    if is_struct(capture, Jido.VFS.Capture) and Keyword.keyword?(opts) and
         Keyword.keys(opts) == [:expected] do
      call(ws, {:replace, Keyword.fetch!(opts, :expected), capture}, :replace)
    else
      error(:replace, ws.id, :invalid_input)
    end
  end

  @doc "Returns the actual execution file source and its revision, when available."
  @spec file_view(t()) :: {:ok, Jido.Workspace.FileView.t()} | {:error, Error.t()}
  def file_view(ws), do: call(ws, :file_view, :file_view)

  @doc """
  Runs a virtual Shell command. Returns an Execution, including nonzero exits.
  Options: `files`, `timeout_ms` (30000), `output_limit` (1048576), and
  `execution_context`. A file view is a check before execution, not a lock.
  """
  @spec run(t(), String.t(), keyword()) :: {:ok, Execution.t()} | {:error, Error.t()}
  def run(ws, command, opts \\ []) do
    with :ok <- command_options(command, opts),
         {:ok, command} <- Schemas.validate_command(command),
         {:ok, id, pid, view} <-
           call(ws, {:command_session, Keyword.get(opts, :files, :current)}, :run) do
      Task.async(fn -> Jido.Workspace.Command.run(ws, id, pid, view, command, opts) end)
      |> Task.await(:infinity)
    else
      {:error, %Error{} = reason} -> {:error, reason}
      {:error, reason} -> error(:run, ws.id, reason)
    end
  end

  @doc "Closes storage and the session. Repeated close returns `:ok`."
  @spec close(t()) :: mutation_result()
  def close(ws) do
    case call(ws, :close, :close) do
      {:error, %Error{code: :closed}} -> :ok
      result -> result
    end
  end

  defp file(ws, path, operation, request, args) do
    with {:ok, path} <- validate_path(path) do
      call(ws, {:file, request, [path | args]}, operation)
    else
      {:error, reason} -> error(operation, ws.id, reason)
    end
  end

  defp call(%Workspace{} = ws, request, operation) do
    case Lifetime.call(ws.lifetime, request) do
      {:error, reason} -> error(operation, ws.id, reason)
      result -> result
    end
  end

  defp error(operation, resource, reason),
    do: {:error, Error.from_reason(operation, resource, reason)}

  defp validate_path(path) when is_binary(path) do
    if String.valid?(path) and not String.contains?(path, <<0>>),
      do: Schemas.validate_path(path),
      else: {:error, :invalid_input}
  end

  defp validate_path(_), do: {:error, :invalid_input}

  defp bytes(content) do
    {:ok, IO.iodata_to_binary(content)}
  rescue
    ArgumentError -> {:error, :invalid_input}
  end

  defp open_options(opts) do
    if Keyword.keyword?(opts) and is_pid(Keyword.get(opts, :owner, self())) and
         Keyword.keyword?(Keyword.get(opts, :adapter_opts, [])) and
         Keyword.keyword?(Keyword.get(opts, :session_opts, [])),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp command_options(command, opts) do
    if is_binary(command) and String.valid?(command) and not String.contains?(command, <<0>>) and
         Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:files, :timeout_ms, :output_limit, :execution_context] == [] and
         is_integer(Keyword.get(opts, :timeout_ms, 30000)) and
         Keyword.get(opts, :timeout_ms, 30000) > 0 and
         is_integer(Keyword.get(opts, :output_limit, 1_048_576)) and
         Keyword.get(opts, :output_limit, 1_048_576) >= 0 and
         is_map(Keyword.get(opts, :execution_context, %{})),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp unique_id, do: "workspace-#{System.unique_integer([:positive, :monotonic])}"
end
