defmodule Jido.Workspace.Sandbox do
  @moduledoc """
  Execution environments with explicit backend and service ownership.

  A local sandbox separates processes. It does not provide OS security isolation.
  Closing a handle leaves services running. Destroying the sandbox stops services
  and removes a directory that Workspace created. A host checkout stays on disk.
  """
  @enforce_keys [:id, :pid, :root]
  defstruct [:id, :pid, :root, :checkout_key, provider: :local, deployment: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid(),
          root: String.t(),
          checkout_key: String.t() | nil,
          provider: atom(),
          deployment: term()
        }

  @doc """
  Opens a sandbox with a backend and fixed policy.

  The default creates a disposable directory. Use `checkout:` on Docker
  or gVisor for an existing host directory.
  """
  def open(opts \\ []) do
    owner = Keyword.get(opts, :owner)

    with true <- is_nil(owner) or is_pid(owner),
         :ok <- Jido.Workspace.Policy.validate(Keyword.get(opts, :policy, :full_access)),
         :ok <- checkout_options(opts),
         {:ok, backend, backend_opts} <- Jido.Workspace.Sandbox.Backend.resolve(opts),
         {:ok, backend_opts} <- Jido.Workspace.Sandbox.Backend.prepare(backend, backend_opts) do
      id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      root = sandbox_root(opts, id)

      spec =
        {Jido.Workspace.Sandbox.Server,
         {id, root, Keyword.get(opts, :policy, :full_access), backend, backend_opts, owner}}

      case DynamicSupervisor.start_child(Jido.Workspace.Sandbox.Supervisor, spec) do
        {:ok, pid} -> request(%__MODULE__{id: id, pid: pid, root: ""}, :handle)
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  defp checkout_options(opts) do
    case Keyword.fetch(opts, :checkout) do
      :error ->
        :ok

      {:ok, path} ->
        if Keyword.get(opts, :provider) in [:local, :docker, :gvisor] and
             not Keyword.has_key?(opts, :root) and is_binary(path) and String.valid?(path) and
             Path.type(path) == :absolute and not String.contains?(path, <<0>>),
           do: :ok,
           else: {:error, :invalid_input}
    end
  end

  defp sandbox_root(opts, id) do
    case Keyword.fetch(opts, :checkout) do
      {:ok, checkout} ->
        {:checkout, Path.expand(checkout)}

      :error ->
        root = Keyword.get(opts, :root, Path.join(System.tmp_dir!(), "jido-sandbox-" <> id))
        {:owned, Path.expand(root)}
    end
  end

  @doc "Gets a handle to a live sandbox by its registered ID."
  def attach(id) do
    case Registry.lookup(Jido.Workspace.Sandbox.Registry, id) do
      [{pid, _root}] -> request(%__MODULE__{id: id, pid: pid, root: ""}, :handle)
      [] -> {:error, :not_found}
    end
  end

  @doc "Reads the capabilities reported by the sandbox backend."
  def capabilities(sandbox), do: request(sandbox, :capabilities)

  @doc false
  def claim_deployment(sandbox, target_id) do
    with {:ok, generation} <- request(sandbox, {:claim_deployment, target_id}) do
      {:ok, %{sandbox | deployment: {target_id, generation}}}
    end
  end

  @doc "Checks an action against the policy stored by the controller."
  def authorize(sandbox, action), do: request(sandbox, {:authorize, action})

  @doc "Reads sandbox identity and service records."
  def info(sandbox), do: request(sandbox, :info)
  @doc "Closes a handle without stopping services or deleting files."
  def close(%__MODULE__{}), do: :ok
  @doc "Stops owned services and removes the directory if the sandbox created it."
  def destroy(sandbox), do: request(sandbox, :destroy)
  @doc "Starts a service after policy, capability, and file checks pass."
  def start_service(sandbox, spec), do: sandbox_result(request(sandbox, {:start_service, spec}))
  @doc "Stops the service identified by its ID."
  def stop_service(sandbox, id), do: request(sandbox, {:stop_service, id})
  @doc "Reads a service status and its recorded result."
  def service_status(sandbox, id), do: sandbox_result(request_service_status(sandbox, id))

  @doc "Calls a BEAM service through its private standard-input control channel."
  def call(sandbox, id, module, function, args, timeout \\ 5_000) do
    if sandbox.deployment do
      request(sandbox, {:deployment_call, id, module, function, args, timeout})
    else
      with {:ok, peer} <- request(sandbox, {:peer, id}) do
        try do
          {:ok, :peer.call(peer, module, function, args, timeout)}
        catch
          kind, reason -> {:error, {:target_call, kind, reason}}
        end
      end
    end
  end

  @doc "Runs an executable with an argument list. No implicit shell is used."
  def exec(sandbox, executable, args, opts \\ []),
    do: sandbox_result(exec(sandbox, executable, args, opts, %{}))

  defp sandbox_result({:error, {:start_failed, reason}}), do: {:error, reason}
  defp sandbox_result(result), do: result

  defp request_service_status(sandbox, id), do: request(sandbox, {:service_status, id})

  @doc false
  def exec(sandbox, executable, args, opts, control) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    spec = %{
      kind: :exec,
      executable: executable,
      args: args,
      dir: Keyword.get(opts, :dir, "."),
      env: Keyword.get(opts, :env, []),
      timeout: timeout,
      output_limit: Keyword.get(opts, :output_limit, 65_536),
      files: Keyword.get(opts, :files, :current),
      stdin: Map.get(control, :stdin, :closed),
      connector: control[:connector]
    }

    with {:ok, id} <- request(sandbox, {:start_service, spec, control[:io_buffer]}) do
      await(sandbox, id, System.monotonic_time(:millisecond) + timeout + 2_000, control[:stop])
    end
  end

  defp await(sandbox, id, deadline, stop) do
    case request_service_status(sandbox, id) do
      {:ok, %{status: :running, cleanup_error: error}} ->
        error

      {:ok, %{status: :running}} ->
        await_running(sandbox, id, deadline, stop)

      result ->
        result
    end
  end

  defp await_running(sandbox, id, deadline, stop) do
    cond do
      stop && :atomics.get(stop, 1) == 1 ->
        stop_command(sandbox, id, :cancelled)

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await(sandbox, id, deadline, stop)

      is_nil(stop) ->
        with :ok <- stop_service(sandbox, id), do: {:error, :timeout}

      true ->
        stop_command(sandbox, id, :timed_out)
    end
  end

  defp stop_command(sandbox, id, status) do
    with :ok <- stop_service(sandbox, id) do
      case request_service_status(sandbox, id) do
        {:ok, %{status: :stopped} = service} -> {:ok, %{service | status: status}}
        result -> result
      end
    end
  end

  @doc "Resolves a provider path from the controller-owned root."
  def path(sandbox, relative), do: files(sandbox, :path, [relative])
  @doc "Gets the canonical target identity and provider location for a relative path."
  def location(sandbox, relative), do: request(sandbox, {:location, relative})
  @doc "Reads a file through the sandbox path and policy checks."
  def read(sandbox, relative), do: files(sandbox, :read, [relative])

  @doc false
  def read(sandbox, relative, limit), do: files(sandbox, :read, [relative, limit])

  @doc false
  def read(sandbox, relative, offset, count), do: files(sandbox, :read, [relative, offset, count])

  @doc false
  def upload(sandbox, action), do: request(sandbox, {:upload, action})

  @doc "Creates a directory. Parent directories are created when parents is true."
  def mkdir(sandbox, relative, parents \\ true), do: files(sandbox, :mkdir, [relative, parents])

  @doc false
  def delete(sandbox, relative), do: files(sandbox, :delete, [relative])

  @doc false
  def write_checked(sandbox, relative, bytes, check),
    do: files(sandbox, :write_checked, [relative, bytes, check])

  @doc "Moves an entry to an unused path in the sandbox."
  def move(sandbox, source, destination), do: files(sandbox, :move, [source, destination])

  @doc "Reads a symbolic link without following its final path component."
  def read_link(sandbox, relative), do: files(sandbox, :read_link, [relative])

  @doc "Replaces a symbolic link through a temporary link and an atomic rename."
  def replace_link(sandbox, relative, destination, nonce),
    do: files(sandbox, :replace_link, [relative, destination, nonce])

  @doc "Checks file bytes, modes, and optional directory paths. A tracked check permits additions."
  def verify_files(sandbox, relative, entries, tracked \\ false, directories \\ nil),
    do: files(sandbox, :verify, [relative, entries, tracked, directories])

  @doc "Checks the OTP release layout and prepares release metadata when requested."
  def release_files(sandbox, relative, version, initialize \\ false),
    do: request(sandbox, {:release_files, relative, version, initialize})

  @doc "Captures the source identity and revision for a relative directory."
  def file_view(sandbox, relative \\ "."), do: request(sandbox, {:file_view, relative})

  defp files(sandbox, operation, args), do: request(sandbox, {:files, operation, args})

  @doc "Writes file bytes and applies a regular or executable file mode."
  def write(sandbox, relative, bytes, mode \\ 0o644) when mode in [0o644, 0o755] do
    request(sandbox, {:write, relative, bytes, mode})
  end

  defp request(%__MODULE__{pid: pid, deployment: deployment}, message) do
    message = if deployment, do: {:deployment, deployment, message}, else: message

    try do
      GenServer.call(pid, message, 30_000)
    catch
      :exit, reason -> {:error, {:sandbox_unavailable, reason}}
    end
  end
end
