defmodule Jido.Workspace do
  @moduledoc """
  Working files, command execution, and durable snapshots.

  Keep the same handle for the resource lifetime. The controller owns storage,
  policy, and session state. File changes and session stop return `:ok`.
  All failures return `Jido.Workspace.Error`.

  Use paths relative to the root on a profiled workspace and absolute paths on
  a workspace opened without a profile.
  """
  alias Jido.Workspace.{Entry, Error, Execution, Info, Lifetime, Profile, ProfileSession}
  alias Jido.Workspace.{Schemas, Snapshot, SnapshotStore, Workspace}

  @legacy_options [:id, :owner, :policy, :adapter, :adapter_opts, :session_opts, :start_session]
  @profile_options [:id, :owner, :profile, :from]
  @run_options Zoi.keyword(
                 [
                   cwd: Zoi.string() |> Zoi.default("."),
                   timeout_ms:
                     Zoi.integer() |> Zoi.min(1) |> Zoi.max(60_000) |> Zoi.default(30_000),
                   output_limit:
                     Zoi.integer() |> Zoi.min(0) |> Zoi.max(1_048_576) |> Zoi.default(1_048_576)
                 ],
                 unrecognized_keys: :error
               )
  @type t :: Workspace.t()
  @type mutation_result :: :ok | {:error, Error.t()}

  @doc "Opens a workspace. Use `profile:` for a named host profile and `from:` for a saved reference."
  @spec open(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(opts \\ []) do
    with :ok <- open_options(opts),
         {:ok, id} <- Schemas.validate_workspace_id(Keyword.get_lazy(opts, :id, &unique_id/0)),
         {:ok, lifetime} <- start(id, Keyword.put_new(opts, :owner, self())) do
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

  @doc "Reads file bytes."
  @spec read(t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read(ws, path), do: file(ws, path, :read, :read_file, [])

  @doc "Writes iodata to a file."
  @spec write(t(), String.t(), iodata()) :: mutation_result()
  def write(ws, path, content) do
    with {:ok, bytes} <- bytes(content) do
      file(ws, path, :write, :write_file, [bytes])
    else
      {:error, reason} -> error(:write, ws.id, reason)
    end
  end

  @doc "Creates a directory."
  @spec mkdir(t(), String.t()) :: mutation_result()
  def mkdir(ws, path), do: file(ws, path, :mkdir, :mkdir, [])

  @doc "Deletes a file or an empty directory."
  @spec delete(t(), String.t()) :: mutation_result()
  def delete(ws, path), do: file(ws, path, :delete, :delete, [])

  @doc "Lists entries in path order. Unknown metadata is nil."
  @spec list(t(), String.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def list(%Workspace{lifetime: {:profile, _}} = ws), do: list(ws, ".")
  def list(ws), do: list(ws, "/")

  def list(%Workspace{lifetime: {:profile, _}} = ws, path), do: profile_file(ws, :list, path, [])

  def list(ws, path) do
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

  @doc "Saves a profiled workspace to its configured store and returns a durable reference."
  @spec save(t()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def save(%Workspace{lifetime: {:profile, _}} = ws), do: call(ws, :save, :save)
  def save(ws), do: error(:save, ws.id, :unsupported_capability)

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
  Runs argv on a profiled workspace. Options are `cwd:`, `timeout_ms:`, and
  `output_limit:`. A workspace opened without a profile takes a virtual Shell
  command string and also accepts `files:` and `execution_context:`.
  """
  @spec run(t(), String.t() | [String.t(), ...], keyword()) ::
          {:ok, Execution.t()} | {:error, Error.t()}
  def run(ws, command, opts \\ [])

  def run(%Workspace{lifetime: {:profile, _}} = ws, command, opts) do
    with [tool | _] when is_binary(tool) and byte_size(tool) > 0 <- command,
         true <- valid_arguments?(command),
         true <- Keyword.keyword?(opts) and unique_keys?(opts),
         {:ok, opts} <- Zoi.parse(@run_options, opts),
         true <- Schemas.relative_path?(Keyword.fetch!(opts, :cwd)) do
      call(ws, {:profile_run, command, Map.new(opts)}, :run)
    else
      _ -> error(:run, ws.id, :invalid_input)
    end
  end

  def run(ws, command, opts) do
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

  @doc "Closes storage and the session. A profiled workspace releases its owned runtime."
  @spec close(t()) :: mutation_result()
  def close(ws) do
    case call(ws, :close, :close) do
      {:error, %Error{code: :closed}} -> :ok
      result -> result
    end
  end

  defp file(%Workspace{lifetime: {:profile, _}} = ws, path, operation, _request, args),
    do: profile_file(ws, operation, path, args)

  defp file(ws, path, operation, request, args) do
    with {:ok, path} <- validate_path(path) do
      call(ws, {:file, request, [path | args]}, operation)
    else
      {:error, reason} -> error(operation, ws.id, reason)
    end
  end

  defp profile_file(ws, operation, path, args) do
    if Schemas.relative_path?(path) and (path != "." or operation == :list),
      do: call(ws, {:profile_file, operation, [path | args]}, operation),
      else: error(operation, ws.id, :invalid_input)
  end

  defp call(%Workspace{} = ws, request, operation) do
    case request(ws.lifetime, request) do
      {:error, %Error{} = reason} -> {:error, %{reason | operation: operation, resource: ws.id}}
      {:error, reason} -> error(operation, ws.id, reason)
      result -> result
    end
  end

  defp request({:profile, pid}, message), do: ProfileSession.call(pid, message)
  defp request(pid, message), do: Lifetime.call(pid, message)

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
         unique_keys?(opts) and known_open_options?(opts),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp known_open_options?(opts) do
    if Keyword.has_key?(opts, :profile) do
      Keyword.keys(opts) -- @profile_options == []
    else
      Keyword.keys(opts) -- @legacy_options == [] and
        Keyword.keyword?(Keyword.get(opts, :adapter_opts, [])) and
        Keyword.keyword?(Keyword.get(opts, :session_opts, []))
    end
  end

  defp start(id, opts) do
    case Keyword.fetch(opts, :profile) do
      {:ok, name} ->
        with {:ok, profile} <- Profile.fetch(name),
             {:ok, capture} <- load_snapshot(profile, Keyword.fetch(opts, :from)),
             {:ok, pid} <- ProfileSession.start({id, opts[:owner], profile, capture}) do
          {:ok, {:profile, pid}}
        end

      :error ->
        Lifetime.start(id, opts)
    end
  end

  defp load_snapshot(_, :error), do: {:ok, nil}

  defp load_snapshot(profile, {:ok, snapshot}),
    do: SnapshotStore.fetch(Map.get(profile, :store), snapshot)

  defp valid_arguments?([arg | rest]) when is_binary(arg),
    do: String.valid?(arg) and not String.contains?(arg, <<0>>) and valid_arguments?(rest)

  defp valid_arguments?([]), do: true
  defp valid_arguments?(_), do: false

  defp unique_keys?(opts), do: Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts))

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
