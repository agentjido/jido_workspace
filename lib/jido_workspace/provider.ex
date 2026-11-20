defmodule Jido.Workspace.Provider do
  @moduledoc """
  Host-supplied callbacks for one working tree and its command runner.

  Select a trusted module with `provider: {MyApp.Provider, options}` in a
  named profile. Workspace validates public requests and checks policy.
  The provider shares one tree between file calls, commands, and capture.
  It confines paths, enforces the requested tree access for commands, and
  reports only the guarantees it can enforce.

  The lease ID exists before provisioning. Release must revoke that ID,
  stop or fence its writers, and release its session resources. It must
  work after partial provisioning, before a late provision result, and
  on repeat calls. Return `:ok` only after confirming release. The
  host owns any infrastructure that persists beyond the lease.

  A persistent provider must check the lease when it admits file requests,
  commands, and captures. Serialize that check and admission with revocation
  at the provider. Return `:lease_revoked` when it can prove the lease
  cannot admit the operation. Return `:quiescence_unknown` when it cannot
  determine the lease or writer state. An expired timer or lost BEAM alone
  cannot establish that a writer has stopped.

  An external session with tree write access also holds the writer slot.
  Use the provider's control plane to grant that access. Before granting
  another lease, verify that the external session cannot start more work
  and that its existing writers have stopped.
  """

  alias Jido.VFS.Capture
  alias Jido.Workspace.{CommandRef, Entry, InfrastructureRef}

  @type lease :: %{
          id: String.t(),
          workspace_id: String.t(),
          controller: pid(),
          infrastructure: InfrastructureRef.t() | nil
        }
  @type path :: String.t()
  @type limit :: non_neg_integer() | :infinity
  @type reason :: atom() | {:unsupported_capability, atom()}
  @type settings :: %{
          options: term(),
          tree_access: :read_only | :read_write,
          require: map(),
          limits: map()
        }
  @type capabilities :: %{
          required(:tree_access) => :read_only | :read_write,
          optional(:isolation) => :mediated | :process | :container | :gvisor,
          optional(:network) => :disabled | :host,
          optional(:cancellation) => :cooperative | :direct_child | :process_group | :container,
          optional(:runtime_limits) => map()
        }
  @type file_request ::
          {:read, path(), limit()}
          | {:read, path(), non_neg_integer(), pos_integer()}
          | {:list, path(), limit()}
          | {:write, path(), binary(), :any | {:revision, String.t()}}
          | {:check_write, path()}
          | {:mkdir, path()}
          | {:move, path(), path()}
          | {:delete, path()}
  @type command :: %{
          required(:id) => String.t(),
          required(:argv) => [String.t(), ...],
          required(:cwd) => path(),
          required(:timeout_ms) => pos_integer(),
          required(:output_limit) => non_neg_integer(),
          required(:emit) => (binary() -> :ok),
          required(:stop_reason) => (-> nil | :cancelled | :timed_out),
          optional(:command) => CommandRef.t()
        }
  @type command_result ::
          {:exited, non_neg_integer()} | :cancelled | :timed_out

  @doc """
  Acquires the lease and returns an opaque live environment and capabilities.

  Install the supplied capture before returning success. A nil capture
  leaves the initial tree to the provider. An error after allocation still
  leaves the lease subject to release. Bound calls to the upstream provider.

  For a persistent lease, attach to its exact infrastructure reference and
  return the confirmed reference as the fourth element. Verify host access
  and acquire the writer lease at the provider boundary. Refuse admission
  when a previous writer can still act or when its state is unknown.
  """
  @callback provision(lease(), settings(), Capture.t() | nil) ::
              {:ok, term(), capabilities()}
              | {:ok, term(), capabilities(), InfrastructureRef.t()}
              | {:error, reason()}

  @doc """
  Operates on canonical paths relative to the tree. A list uses path order
  and honors the entry limit. A full read over its limit returns
  `:discovery_byte_limit`. The chunk read returns at most the requested bytes.

  Check a revision and edit the file in one operation. The revision is the
  lowercase SHA-256 digest of the current file bytes. A missing file or
  a digest mismatch returns `:stale_revision`. The check-write request
  performs preflight for a streamed write. It must leave the tree intact.
  Return `:quiescence_unknown` if a failed mutation may still be running.
  """
  @callback file(term(), file_request()) ::
              :ok | {:ok, binary() | [Entry.t()]} | {:error, reason()}

  @doc """
  Runs literal argv in the current tree. Emit bytes from one producer
  and check `stop_reason` during the run. Stop emitting before returning.
  The controller bounds the result prefix and live output window.

  Return an outcome only after confirming all of the command's writers
  stopped. Return `:start_failed` for a confirmed failure to start a
  writer and `:quiescence_unknown` when the result cannot establish
  that writers stopped. Workspace never retries a command implicitly.

  With `command`, record the durable reference at the provider boundary
  before starting a writer. Keep it available after a lost launch reply or
  Workspace node exit. On duplicate launch return `:command_reference_used`
  without starting a new writer. This requires the optional recovery callback.
  """
  @callback run(term(), command()) :: {:ok, command_result()} | {:error, reason()}

  @doc """
  Captures the current quiescent tree within the supplied entry and byte limits.

  Confirm the lease and capture the tree under the same writer exclusion.
  The returned bytes form a self-contained tree that Workspace can save.
  """
  @callback capture(term(), %{entries: pos_integer(), bytes: pos_integer()}) ::
              {:ok, Capture.t()} | {:error, reason()}

  @doc """
  Revokes the lease and confirms that its writers and session resources are gone.

  Preserve any persistent infrastructure. Use the lease ID to ensure release
  cannot revoke a different session on the same machine. When old writers
  remain possible, report uncertainty and keep later writers blocked.
  Revocation first bars new work from the old lease. Retain its claim until
  the provider also confirms that all work it already admitted has settled.
  The host can use its provider's control plane when a BEAM cannot release.
  """
  @callback release(lease(), term()) :: :ok | {:error, reason()}

  @doc """
  Recovers a durable command on a host resource without acquiring a lease.

  Verify the reference and host authority. Inspect reports known state.
  Wait can report `:running` shortly before its reply deadline. Stop is
  safe to repeat and reports exit only when the command and its writers
  are stopped. Return `:command_not_found` only for confirmed absence and
  `:quiescence_unknown` for uncertain state. Recovery must not grant a lease.
  """
  @callback recover_command(CommandRef.t(), :inspect | :wait | :stop, pos_integer(), term()) ::
              {:ok, :running | {:exited, non_neg_integer()}} | {:error, reason()}

  @optional_callbacks recover_command: 4

  @doc false
  def configured?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(
        __MODULE__.behaviour_info(:callbacks) -- __MODULE__.behaviour_info(:optional_callbacks),
        fn {name, arity} ->
          function_exported?(module, name, arity)
        end
      )
  end

  @doc false
  def call(module, callback, args, failure) do
    apply(module, callback, args)
  rescue
    _ -> {:error, failure}
  catch
    _, _ -> {:error, failure}
  end

  @doc "Returns the lowercase SHA-256 revision of file bytes."
  def content_revision(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc "Checks a read result against the expected revision inside a file mutation."
  def check_revision({:ok, bytes}, expected) do
    if content_revision(bytes) == expected, do: :ok, else: {:error, :stale_revision}
  end

  def check_revision({:error, reason}, _) when reason in [:enoent, :not_found],
    do: {:error, :stale_revision}

  def check_revision(error, _), do: error
end
