defmodule Jido.Workspace do
  @moduledoc """
  Working files, command execution, and durable snapshots.

  Keep the same handle for the resource lifetime. The controller owns storage,
  policy, and session state. File changes and session stop return `:ok`.
  All failures return `Jido.Workspace.Error`.

  Use paths relative to the root on a profiled workspace and absolute paths on
  a workspace opened without a profile.
  """
  alias Jido.Workspace.{CommandIO, CommandRef, Entry, Error, Execution, Info, Lifetime, Policy}
  alias Jido.Workspace.{Profile, ProfileProvider, ProfileSession, Provider}
  alias Jido.Workspace.{Schemas, Snapshot, SnapshotStore, Workspace}

  @legacy_options [:id, :owner, :policy, :adapter, :adapter_opts, :session_opts, :start_session]
  @profile_options [:id, :owner, :profile, :from, :infrastructure, :timeout_ms]
  @lifecycle_timeout 30_000
  @batch_max_steps 64
  @batch_max_request_bytes 4_194_304
  @input_max_bytes 16_384
  @file_chunk_max_bytes 1_048_576
  @run_options Zoi.keyword(
                 [
                   cwd: Zoi.string() |> Zoi.default("."),
                   timeout_ms: Schemas.run_timeout_schema() |> Zoi.default(30_000),
                   output_limit: Schemas.run_output_limit_schema() |> Zoi.default(1_048_576),
                   stdin: Zoi.enum([:closed, :pipe]) |> Zoi.default(:closed),
                   notify_start: Zoi.optional(Zoi.tuple({Zoi.pid(), Zoi.reference()})),
                   command: Zoi.optional(CommandRef.schema())
                 ],
                 unrecognized_keys: :error
               )
  @type t :: Workspace.t()
  @type mutation_result :: :ok | {:error, Error.t()}
  @type recovered_command ::
          %{status: :running, exit_status: nil}
          | %{status: :exited, exit_status: non_neg_integer()}
  @type file_revision :: String.t()
  @type output_slice :: %{
          bytes: binary(),
          next_offset: non_neg_integer(),
          dropped_bytes: non_neg_integer(),
          done?: boolean()
        }
  @type batch_step ::
          {:mkdir, String.t()}
          | {:write, String.t(), iodata()}
          | {:run, [String.t(), ...], keyword()}
  @type batch_report ::
          %{status: :completed, results: [:ok | Execution.t()]}
          | %{
              status: :halted,
              results: [:ok | Execution.t()],
              failure: %{index: pos_integer(), result: Execution.t() | Error.t()}
            }

  defguardp execution_id?(id) when is_binary(id) and byte_size(id) in 1..1024

  @doc """
  Opens a workspace. Use `profile:` for a named host profile and `from:` for a
  saved reference. A profile with a host checkout opens the existing tree
  and refuses `from:`. Restore requires import permission for the profile's
  store. The caller owns the handle unless it supplies `owner:`.
  Use `infrastructure:` to attach a persistent provider profile to a
  host-acquired infrastructure reference. The provider confirms the
  resource identity before open succeeds. Close releases the lease
  and preserves the machine. Use `from:` on a separate restore profile.
  A persistent provider can refuse open while an earlier lease can still
  write or a maintainer holds write access. A handle with confirmed
  revocation reports `:lease_revoked` on new work. The host reconciles
  older leases and maintainer access through the provider.
  An unmet isolation requirement returns `:unsupported_capability`.
  If the Docker engine does not list the selected runtime, open returns
  `:runtime_unavailable` with the runtime name in the error details.
  For a profiled workspace, `timeout_ms:` bounds the wait for allocation and
  restore after the profile and snapshot are loaded (default 30,000 ms).
  On `:open_timeout`, no handle is returned. The controller releases resources
  if allocation finishes late. The controller also releases them if the
  caller exits before accepting the handle or the owner exits.
  """
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

  @doc """
  Returns identity, policy, owner, and session status. Profiled workspaces
  also report their phase, active execution ID, per-command ceilings, and
  provider capabilities at open. These fields are available with a read-only
  profile and contain no command arguments or output.
  """
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

  @doc """
  Use `revision: true` on a profiled workspace to return the bytes and their
  content revision. Pass that revision to `write/4` to check a later edit.
  """
  @spec read(t(), String.t(), keyword()) ::
          {:ok, binary()} | {:ok, binary(), file_revision()} | {:error, Error.t()}
  def read(ws, path, []), do: read(ws, path)

  def read(%Workspace{lifetime: {:profile, _}} = ws, path, revision: true) do
    with {:ok, bytes} <- read(ws, path), do: {:ok, bytes, Provider.content_revision(bytes)}
  end

  def read(ws, _, revision: true), do: error(:read, ws.id, :unsupported_capability)
  def read(ws, _, _), do: error(:read, ws.id, :invalid_input)

  @doc """
  Writes iodata to a file. A profiled workspace creates missing parent
  directories and replaces the specified entry. Native replacements
  preserve the file mode and leave other hard-link entries unchanged.
  """
  @spec write(t(), String.t(), iodata()) :: mutation_result()
  def write(ws, path, content) do
    with {:ok, bytes} <- bytes(content) do
      file(ws, path, :write, :write_file, [bytes])
    else
      {:error, reason} -> error(:write, ws.id, reason)
    end
  end

  @doc """
  Use `expected:` to update a file in a profiled workspace when its current
  bytes match the revision returned by `read/3`. A changed or removed file
  returns `:stale_revision`. The provider checks and edits the file in one
  operation. The revision describes content, so the same bytes match again
  if another edit restores them.
  """
  @spec write(t(), String.t(), iodata(), keyword()) :: mutation_result()
  def write(ws, path, content, []), do: write(ws, path, content)

  def write(ws, path, content, expected: revision)
      when is_binary(revision) and byte_size(revision) == 64 do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, revision),
         {:ok, bytes} <- bytes(content) do
      case ws do
        %Workspace{lifetime: {:profile, _}} ->
          profile_file(ws, :write, path, [bytes, {:revision, revision}])

        %Workspace{} ->
          error(:write, ws.id, :unsupported_capability)
      end
    else
      _ -> error(:write, ws.id, :invalid_input)
    end
  end

  def write(ws, _, _, _), do: error(:write, ws.id, :invalid_input)

  @doc """
  Reads up to `count` bytes from `offset` in a profiled workspace.

  The count must be between 1 and 1 MiB. An empty binary indicates the end
  of the file. Each call reads the current file.
  """
  @spec read_chunk(t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, Error.t()}
  def read_chunk(%Workspace{lifetime: {:profile, _}} = ws, path, offset, count) do
    if profile_file_path?(:read, path) and is_integer(offset) and
         offset in 0..0x7FFF_FFFF_FFFF_FFFF and is_integer(count) and
         count in 1..@file_chunk_max_bytes do
      call(ws, {:profile_file, :read, [path, offset, count]}, :read_chunk)
    else
      error(:read_chunk, ws.id, :invalid_input)
    end
  end

  def read_chunk(ws, _, _, _), do: error(:read_chunk, ws.id, :unsupported_capability)

  @doc """
  Writes an enumerable of iodata chunks to a file in a profiled workspace.

  Create the parent directory first. Each chunk can contain up to 1 MiB.
  The profile limits the total bytes. The workspace publishes the file after
  the enumerable finishes. Reads can use the current files during the transfer.
  Failure or caller exit before the commit request leaves the destination in
  its previous state.
  """
  @spec write_stream(t(), String.t(), Enumerable.t()) :: mutation_result()
  def write_stream(%Workspace{lifetime: {:profile, _}} = ws, path, chunks) do
    if profile_file_path?(:write, path) do
      with {:ok, ref} <- call(ws, {:begin_upload, path}, :write_stream) do
        case write_chunks(ws, ref, chunks) do
          :ok ->
            call(ws, {:upload, ref, :commit}, :write_stream)

          {:error, _} = error ->
            with :ok <- call(ws, {:upload, ref, :abort}, :write_stream), do: error
        end
      end
    else
      error(:write_stream, ws.id, :invalid_input)
    end
  end

  def write_stream(ws, _, _), do: error(:write_stream, ws.id, :unsupported_capability)

  defp write_chunks(ws, ref, chunks) do
    result =
      Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
        result =
          with {:ok, bytes} <- chunk_bytes(chunk),
               do: call(ws, {:upload, ref, {:chunk, bytes}}, :write_stream)

        case result do
          :ok -> {:cont, :ok}
          {:error, %Error{}} = error -> {:halt, error}
          {:error, reason} -> {:halt, error(:write_stream, ws.id, reason)}
        end
      end)

    case result do
      :ok -> :ok
      {:error, %Error{}} = error -> error
      _ -> error(:write_stream, ws.id, :stream_failed)
    end
  catch
    _, _ -> error(:write_stream, ws.id, :stream_failed)
  end

  defp chunk_bytes(chunk) do
    if IO.iodata_length(chunk) <= @file_chunk_max_bytes,
      do: bytes(chunk),
      else: {:error, :transfer_limit}
  rescue
    ArgumentError -> {:error, :invalid_input}
  end

  @doc "Creates a directory."
  @spec mkdir(t(), String.t()) :: mutation_result()
  def mkdir(ws, path), do: file(ws, path, :mkdir, :mkdir, [])

  @doc "Deletes a file or an empty directory."
  @spec delete(t(), String.t()) :: mutation_result()
  def delete(ws, path), do: file(ws, path, :delete, :delete, [])

  @doc """
  Moves a file or directory within a profiled workspace.

  Both paths are relative to the workspace root. The destination parent
  must exist. An existing destination returns `:already_exists` and
  both entries stay in place.
  """
  @spec move(t(), String.t(), String.t()) :: mutation_result()
  def move(%Workspace{lifetime: {:profile, _}} = ws, source, destination) do
    if profile_file_path?(:move, source) and profile_file_path?(:move, destination) and
         not String.starts_with?(destination, source <> "/") do
      call(ws, {:profile_file, :move, [source, destination]}, :move)
    else
      error(:move, ws.id, :invalid_input)
    end
  end

  def move(%Workspace{} = ws, _, _), do: error(:move, ws.id, :unsupported_capability)

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

  @doc """
  Finds regular files under a relative directory in a profiled workspace.

  Returns entries in path order. With `contains:`, each result contains the
  given literal bytes. The host profile controls hidden paths, excluded
  subtrees, binary content matches, and scan limits.
  """
  @spec find(t(), String.t(), keyword()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def find(ws, path \\ ".", opts \\ [])

  def find(%Workspace{lifetime: {:profile, _}} = ws, path, opts) do
    with true <- Schemas.relative_path?(path),
         {:ok, needle} <- discovery_query(opts) do
      call(ws, {:profile_find, path, needle}, :find)
    else
      _ -> error(:find, ws.id, :invalid_input)
    end
  end

  def find(ws, _, _), do: error(:find, ws.id, :unsupported_capability)

  defp discovery_query([]), do: {:ok, nil}

  defp discovery_query(contains: bytes) when is_binary(bytes) and byte_size(bytes) in 1..4096,
    do: {:ok, bytes}

  defp discovery_query(_), do: :error

  @doc "Captures immutable content and a revision. Multiple mounts are refused."
  @spec capture(t()) :: {:ok, Jido.VFS.Capture.t(), term()} | {:error, Error.t()}
  def capture(ws), do: call(ws, :capture, :capture)

  @doc """
  Writes a snapshot to the profile's store and returns its durable reference.
  Requires save permission. Saving the same tree to the same store returns
  the same reference. A store write failure returns `:snapshot_store_unavailable`.
  Earlier references stay usable when a later publication fails and their
  bundles remain available.
  """
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
  Runs argv on a profiled workspace. Options are `cwd:`, `timeout_ms:`,
  `output_limit:`, and `stdin:`. A profile can cap the execution timeout
  and returned bytes.
  The smaller of the option and the profile limit applies. A workspace
  opened without a profile takes a virtual Shell command string and also
  accepts `files:` and `execution_context:`.

  Set `stdin: :pipe` on a provider that supports it. Another process
  can use `input/3` while this call waits. A profile with service ports
  also permits `connect/3`. Workspace requests cancellation for these
  runs if the caller exits or the workspace starts to close.

  A completed profiled command returns an execution with its exit status and
  bounded combined output. Check `exit_status` for command success. Errors
  such as a missing working directory return `Jido.Workspace.Error`.
  Docker returns `:start_failed` when it confirms the tool did not start
  and confirms removal of the failed container.
  A confirmed cancellation or timeout returns an execution with a nil exit
  status. If the provider cannot confirm that writers stopped, run returns
  `:quiescence_unknown` and fences writes and saves.

  An admitted profiled command has one execution ID. Match
  `info/1`, the execution result or error, and the Telemetry events
  `[:jido_workspace, :command, :start]` and `[:jido_workspace, :command, :stop]`
  by this ID. Event metadata contains IDs and outcome codes.

  Pass `notify_start: {pid, reference}` to send the observing process
  `{:workspace_command_started, reference, execution_id}` when Workspace
  admits the command. This message identifies the output record even if the
  command exits before the observer calls `info/1`. A command rejected
  before admission sends no message. Check the `run/3` result for the outcome.

  On a persistent provider that supports recovery, pass a durable reference
  as `command:`. Record it before calling run so it remains available if
  the reply is lost. Use a new reference for each launch. The provider
  refuses reuse of a reference without launching the command again.
  """
  @spec run(t(), String.t() | [String.t(), ...], keyword()) ::
          {:ok, Execution.t()} | {:error, Error.t()}
  def run(ws, command, opts \\ [])

  def run(%Workspace{lifetime: {:profile, _}} = ws, command, opts) do
    with {:ok, opts} <- profile_run_options(command, opts) do
      call(ws, {:profile_run, command, opts}, :run)
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

  @doc """
  Inspects, waits for, or stops a command on persistent infrastructure.

  Select a host profile with the `:recover` grant and command recovery support.
  The command reference may be a map decoded from JSON. Recovery uses no live
  handle and grants no access to modify or save the working tree.

  Use `:inspect` to read current state, `:wait` to wait up to `timeout_ms:`,
  or `:stop` to request termination and confirm exit. A wait can report
  `:running` when the provider confirms the command remains active. An unknown
  outcome returns `:quiescence_unknown`. Inspect again without relaunching.
  A confirmed exit describes that command. The host must still reconcile the
  old lease and confirm its writers have stopped before a replacement can save.
  The default wait for a reply is 30,000 ms.
  """
  @spec recover_command(atom(), CommandRef.t(), :inspect | :wait | :stop, keyword()) ::
          {:ok, recovered_command()} | {:error, Error.t()}
  def recover_command(profile, command, action, opts \\ []) do
    with :ok <- validate_recovery_action(action),
         {:ok, timeout} <- lifecycle_timeout(opts),
         {:ok, reference} <- parse_command_reference(command),
         {:ok, profile} <- Profile.fetch(profile),
         :ok <- ProfileProvider.admit_recovery(profile),
         {:ok, _} <- Profile.infrastructure(profile, {:ok, reference.infrastructure}),
         :ok <- Policy.authorize(profile.policy, :recover),
         {:ok, status} <- ProfileProvider.recover_command(profile, reference, action, timeout) do
      {:ok, status}
    else
      {:error, reason} -> error(:recover_command, nil, reason)
    end
  end

  defp validate_recovery_action(action) when action in [:inspect, :wait, :stop], do: :ok
  defp validate_recovery_action(_), do: {:error, :invalid_input}

  defp parse_command_reference(value) do
    case CommandRef.parse(value) do
      {:ok, reference} -> {:ok, reference}
      {:error, _} -> {:error, :invalid_command_reference}
    end
  end

  @doc """
  Runs a list of edits and commands on a profiled workspace.

  Supply 1 to 64 steps, with a total Erlang external term size of at most
  4 MiB. Workspace validates the complete request before running a step.
  The batch holds the tree until it settles. Inspect and cancel the active
  command by execution ID as for a direct `run/3`.
  A run step can use `notify_start:` to report its execution ID. The next
  admitted command can replace its output record before an observer reads it.

  The report contains the successful step results in order. A failure
  includes the one-based step index and the execution or error that
  stopped the batch. Earlier changes and changes from the failed step
  can remain. Save is a separate call.

  The profile caps the batch's command time and returned output. The
  deadline also prevents further step admission. An admitted file
  operation or provider cleanup can take longer to settle.
  """
  @spec batch(t(), [batch_step()]) :: {:ok, batch_report()} | {:error, Error.t()}
  def batch(%Workspace{lifetime: {:profile, _}} = ws, steps) do
    case batch_steps(steps) do
      {:ok, steps} ->
        call(ws, {:profile_batch, steps}, :batch)

      {:error, index} ->
        {:error,
         %{Error.from_reason(:batch, ws.id, :invalid_input) | details: %{step_index: index}}}

      :error ->
        error(:batch, ws.id, :invalid_input)
    end
  end

  def batch(%Workspace{} = ws, _), do: error(:batch, ws.id, :unsupported_capability)

  @doc """
  Requests cancellation of the active command with this execution ID.

  Read the ID with `info/1`. A successful request returns `:ok`.
  Wait for the original `run/3` or `batch/2` result to confirm the
  outcome. Writes and saves stay fenced while the command can still write.
  """
  @spec cancel(t(), String.t()) :: mutation_result()
  def cancel(%Workspace{lifetime: {:profile, _}} = ws, execution_id)
      when execution_id?(execution_id) do
    call(ws, {:cancel_execution, execution_id}, :cancel)
  end

  def cancel(%Workspace{lifetime: {:profile, _}} = ws, _),
    do: error(:cancel, ws.id, :invalid_input)

  def cancel(%Workspace{} = ws, _),
    do: error(:cancel, ws.id, :unsupported_capability)

  @doc """
  Reads a slice of command output on a profiled workspace.

  Start at byte offset zero and pass `next_offset` to the next read.
  `dropped_bytes` counts bytes lost before the retained window. The window
  uses the effective command output limit. `done?` is true after the
  controller settles the run. Use the original run result to check whether
  writers stopped. The record lasts until the next admitted command or
  workspace close.
  """
  @spec output(t(), String.t(), non_neg_integer()) ::
          {:ok, output_slice()} | {:error, Error.t()}
  def output(ws, execution_id, offset \\ 0)

  def output(%Workspace{lifetime: {:profile, _}} = ws, execution_id, offset)
      when execution_id?(execution_id) and is_integer(offset) and offset >= 0 do
    call(ws, {:command_output, execution_id, offset}, :output)
  end

  def output(%Workspace{lifetime: {:profile, _}} = ws, _, _),
    do: error(:output, ws.id, :invalid_input)

  def output(%Workspace{} = ws, _, _),
    do: error(:output, ws.id, :unsupported_capability)

  @doc """
  Opens a byte stream to an approved TCP port in the active command container.

  Read the execution ID and the profile's `:service_ports` with `info/1`.
  The connection goes to the container's IPv4 loopback interface. The
  caller owns the Erlang port. Use `Port.command/3` to send bytes and handle
  `{port, {:data, bytes}}` and `{port, {:exit_status, status}}` messages.
  Close the port when finished.

  A successful reply starts the transport. Use the service protocol to
  verify readiness. Retry `:service_not_ready` while the command starts.
  A new call opens a new TCP connection. Stopping the command stops its
  connections. The command's original run result confirms cleanup.
  """
  @spec connect(t(), String.t(), 1..65_535) :: {:ok, port()} | {:error, Error.t()}
  def connect(%Workspace{lifetime: {:profile, _}} = ws, execution_id, port)
      when execution_id?(execution_id) and port in 1..65_535 do
    with {:ok, connector} <- call(ws, {:command_connector, execution_id, port}, :connect) do
      case CommandIO.connect(connector, port) do
        {:ok, connection} -> {:ok, connection}
        {:error, reason} -> error(:connect, ws.id, reason)
      end
    end
  end

  def connect(%Workspace{lifetime: {:profile, _}} = ws, _, _),
    do: error(:connect, ws.id, :invalid_input)

  def connect(%Workspace{} = ws, _, _),
    do: error(:connect, ws.id, :unsupported_capability)

  @doc """
  Sends 1 to 16,384 bytes to an active command opened with `stdin: :pipe`.

  A successful reply means the transport accepted the bytes. Use
  `output/3` to read the program's response. Retry when the transport
  reports `:input_not_ready` or `:input_busy`. Input closes when a
  stop is requested.

  For a credential, the host must select a trusted executable and runtime.
  Send the credential through the pipe. A profile limit of
  `output_limit: 0` discards command output bytes and retains output
  counts. The host controls access to live VM debugging and the runtime.
  """
  @spec input(t(), String.t(), binary()) :: mutation_result()
  def input(%Workspace{lifetime: {:profile, _}} = ws, execution_id, bytes)
      when execution_id?(execution_id) and is_binary(bytes) and
             byte_size(bytes) in 1..@input_max_bytes do
    call(ws, {:command_input, execution_id, bytes}, :input)
  end

  def input(%Workspace{lifetime: {:profile, _}} = ws, _, _),
    do: error(:input, ws.id, :invalid_input)

  def input(%Workspace{} = ws, _, _), do: error(:input, ws.id, :unsupported_capability)

  @doc """
  Closes storage and the session.

  A profiled workspace refuses new work once the controller accepts close.
  Work already in progress can finish before the provider releases the
  workspace. Close requests cancellation of commands with a stdin pipe
  and commands on a profile with service ports.
  Set `timeout_ms:` to bound the caller's wait (default 30,000 ms).
  If release is still unconfirmed, close returns `:cleanup_unconfirmed`. The
  close request can continue after that reply. A repeat call returns `:ok`
  when release was confirmed for this handle.
  """
  @spec close(t(), keyword()) :: mutation_result()
  def close(ws, opts \\ [])

  def close(%Workspace{lifetime: {:profile, session}} = ws, opts) do
    with {:ok, timeout} <- lifecycle_timeout(opts),
         :ok <- ProfileSession.close(session, timeout) do
      :ok
    else
      {:error, reason} -> error(:close, ws.id, reason)
    end
  end

  def close(ws, []) do
    case call(ws, :close, :close) do
      {:error, %Error{code: :closed}} -> :ok
      result -> result
    end
  end

  def close(ws, _opts), do: error(:close, ws.id, :invalid_input)

  defp lifecycle_timeout([]), do: {:ok, @lifecycle_timeout}

  defp lifecycle_timeout(timeout_ms: timeout)
       when is_integer(timeout) and timeout in 1..0xFFFFFFFF,
       do: {:ok, timeout}

  defp lifecycle_timeout(_), do: {:error, :invalid_input}

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
    if profile_file_path?(operation, path),
      do: call(ws, {:profile_file, operation, [path | args]}, operation),
      else: error(operation, ws.id, :invalid_input)
  end

  defp profile_file_path?(operation, path),
    do: Schemas.relative_path?(path) and (path != "." or operation == :list)

  defp profile_run_options([tool | _] = argv, opts)
       when is_binary(tool) and byte_size(tool) > 0 do
    with true <- valid_arguments?(argv) and Keyword.keyword?(opts) and unique_keys?(opts),
         {:ok, opts} <- Zoi.parse(@run_options, opts),
         true <- Schemas.relative_path?(Keyword.fetch!(opts, :cwd)) do
      {:ok, Map.new(opts)}
    else
      _ -> :error
    end
  end

  defp profile_run_options(_, _), do: :error

  defp batch_steps(steps) when length(steps) in 1..@batch_max_steps do
    if :erlang.external_size(steps) <= @batch_max_request_bytes,
      do: validate_steps(steps, 1, []),
      else: :error
  end

  defp batch_steps(_), do: :error

  defp validate_steps([], _, valid), do: {:ok, Enum.reverse(valid)}

  defp validate_steps([step | rest], index, valid) do
    case batch_step(step) do
      {:ok, step} -> validate_steps(rest, index + 1, [step | valid])
      _ -> {:error, index}
    end
  end

  defp batch_step({:mkdir, path}) do
    if profile_file_path?(:mkdir, path), do: {:ok, {:mkdir, [path]}}
  end

  defp batch_step({:write, path, content}) do
    with true <- profile_file_path?(:write, path),
         {:ok, bytes} <- bytes(content) do
      {:ok, {:write, [path, bytes]}}
    end
  end

  defp batch_step({:run, argv, opts}) do
    with {:ok, %{stdin: :closed} = opts} <- profile_run_options(argv, opts),
         false <- Map.has_key?(opts, :command) do
      {:ok, {:run, argv, opts}}
    else
      _ -> :error
    end
  end

  defp batch_step(_), do: :error

  defp call(%Workspace{} = ws, request, operation) do
    case request(ws.lifetime, request) do
      {:error, %Error{} = reason} -> {:error, %{reason | operation: operation, resource: ws.id}}
      {:error, reason} -> error(operation, ws.id, reason)
      result -> result
    end
  end

  defp request({:profile, {pid, _release}}, message), do: ProfileSession.call(pid, message)
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
        with {:ok, timeout} <- lifecycle_timeout(Keyword.take(opts, [:timeout_ms])),
             {:ok, profile} <- Profile.fetch(name),
             {:ok, infrastructure} <-
               Profile.infrastructure(profile, Keyword.fetch(opts, :infrastructure)),
             {:ok, capture} <- load_snapshot(profile, Keyword.fetch(opts, :from)) do
          ProfileSession.start({id, opts[:owner], profile, capture, infrastructure}, timeout)
        end

      :error ->
        Lifetime.start(id, opts)
    end
  end

  defp load_snapshot(_, :error), do: {:ok, nil}

  defp load_snapshot(%{infrastructure: _}, {:ok, _}),
    do: {:error, :infrastructure_restore_unsupported}

  defp load_snapshot(%{checkout: _}, {:ok, _}), do: {:error, :checkout_restore_unsupported}

  defp load_snapshot(profile, {:ok, snapshot}) do
    with {:ok, _reference, capture} <- SnapshotStore.fetch(profile, snapshot), do: {:ok, capture}
  end

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
