defmodule Jido.Workspace.Sandbox do
  @moduledoc """
  Execution environments with explicit backend and service ownership.

  A local sandbox separates processes. It does not provide OS security isolation.
  Closing a handle leaves services running. Destroying the sandbox stops services
  and removes its owned directory. Services do not survive controller shutdown.
  """
  @enforce_keys [:id, :pid, :root]
  defstruct [:id, :pid, :root, provider: :local, deployment: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid(),
          root: String.t(),
          provider: atom(),
          deployment: term()
        }

  def open(opts \\ []) do
    with :ok <- Jido.Workspace.Policy.validate(Keyword.get(opts, :policy, :full_access)),
         {:ok, backend, backend_opts} <- Jido.Workspace.Sandbox.Backend.resolve(opts) do
      id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      root =
        Path.expand(Keyword.get(opts, :root, Path.join(System.tmp_dir!(), "jido-sandbox-" <> id)))

      spec =
        {Jido.Workspace.Sandbox.Server,
         {id, root, Keyword.get(opts, :policy, :full_access), backend, backend_opts}}

      case DynamicSupervisor.start_child(Jido.Workspace.Sandbox.Supervisor, spec) do
        {:ok, pid} -> GenServer.call(pid, :handle)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = error -> error
    end
  end

  def attach(id) do
    case Registry.lookup(Jido.Workspace.Sandbox.Registry, id) do
      [{pid, _root}] -> request(%__MODULE__{id: id, pid: pid, root: ""}, :handle)
      [] -> {:error, :not_found}
    end
  end

  def capabilities(sandbox), do: request(sandbox, :capabilities)

  @doc false
  def claim_deployment(sandbox, target_id) do
    with {:ok, generation} <- request(sandbox, {:claim_deployment, target_id}) do
      {:ok, %{sandbox | deployment: {target_id, generation}}}
    end
  end

  def authorize(sandbox, action), do: request(sandbox, {:authorize, action})

  def info(sandbox), do: request(sandbox, :info)
  def close(%__MODULE__{}), do: :ok
  def destroy(sandbox), do: request(sandbox, :destroy)
  def start_service(sandbox, spec), do: request(sandbox, {:start_service, spec})
  def stop_service(sandbox, id), do: request(sandbox, {:stop_service, id})
  def service_status(sandbox, id), do: request(sandbox, {:service_status, id})

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
  def exec(sandbox, executable, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    spec = %{
      kind: :exec,
      executable: executable,
      args: args,
      dir: Keyword.get(opts, :dir, "."),
      env: Keyword.get(opts, :env, []),
      timeout: timeout,
      output_limit: Keyword.get(opts, :output_limit, 65_536),
      files: Keyword.get(opts, :files, :current)
    }

    with {:ok, id} <- start_service(sandbox, spec) do
      await(sandbox, id, System.monotonic_time(:millisecond) + timeout + 2_000)
    end
  end

  defp await(sandbox, id, deadline) do
    case service_status(sandbox, id) do
      {:ok, %{status: :running, cleanup_error: error}} ->
        error

      {:ok, %{status: :running}} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await(sandbox, id, deadline)
        else
          case stop_service(sandbox, id) do
            :ok -> {:error, :timeout}
            error -> error
          end
        end

      result ->
        result
    end
  end

  @doc "Resolves a provider path from the controller-owned root."
  def path(sandbox, relative), do: files(sandbox, :path, [relative])
  def location(sandbox, relative), do: request(sandbox, {:location, relative})
  def read(sandbox, relative), do: files(sandbox, :read, [relative])
  def mkdir(sandbox, relative, parents \\ true), do: files(sandbox, :mkdir, [relative, parents])
  def read_link(sandbox, relative), do: files(sandbox, :read_link, [relative])

  def replace_link(sandbox, relative, destination, nonce),
    do: files(sandbox, :replace_link, [relative, destination, nonce])

  def verify_files(sandbox, relative, entries, tracked \\ false),
    do: files(sandbox, :verify, [relative, entries, tracked])

  def release_files(sandbox, relative, version, initialize \\ false),
    do: request(sandbox, {:release_files, relative, version, initialize})

  def file_view(sandbox, relative \\ "."), do: request(sandbox, {:file_view, relative})

  defp files(sandbox, operation, args), do: request(sandbox, {:files, operation, args})

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
