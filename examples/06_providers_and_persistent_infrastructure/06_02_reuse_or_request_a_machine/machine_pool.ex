defmodule Jido.Workspace.Examples.MachinePool do
  @moduledoc false

  alias Jido.Workspace.InfrastructureRef

  @provider "local-machines"
  @label "dev.jido.workspace.example.machine-pool"
  @enforce_keys [:pid, :docker, :endpoint, :tag, :root, :image]
  defstruct @enforce_keys

  # The sample host owns the containers, their roots, and lease admission.
  def start(root, image) do
    root = Path.expand(root)

    with false <- String.contains?(root, [",", "\"", "\n", "\r"]),
         docker when is_binary(docker) <- System.find_executable("docker"),
         {:ok, endpoint} <- local_endpoint(docker),
         {:ok, pid} <-
           Agent.start(fn -> %{requests: %{}, machines: %{}, revoked: MapSet.new()} end) do
      tag = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      {:ok,
       %__MODULE__{
         pid: pid,
         docker: docker,
         endpoint: endpoint,
         tag: tag,
         root: root,
         image: image
       }}
    else
      _ -> {:error, :infrastructure_unavailable}
    end
  end

  def provider, do: @provider

  def tree(pool, %{resource_id: id}) do
    Agent.get(pool.pid, fn state -> Map.fetch!(state.machines, id).root end)
  end

  def request(pool, request_id) when is_binary(request_id) do
    Agent.get_and_update(
      pool.pid,
      fn state ->
        case Map.fetch(state.requests, request_id) do
          {:ok, reference} -> {{:ok, reference}, state}
          :error -> allocate(pool, state, request_id)
        end
      end,
      15_000
    )
  end

  defp allocate(pool, state, request_id) do
    suffix = Base.encode16(:crypto.hash(:sha256, request_id), case: :lower)
    name = "jido-example-machine-" <> pool.tag <> "-" <> suffix
    root = Path.join(pool.root, suffix)

    with :ok <- File.mkdir_p(root),
         {:ok, %{id: id, running: true}} <- ensure_machine(pool, name, root),
         {:ok, reference} <- InfrastructureRef.new(@provider, id) do
      machine = %{reference: reference, root: root, lease: nil}
      state = put_in(state.requests[request_id], reference)
      {{:ok, reference}, put_in(state.machines[id], machine)}
    else
      _ -> {{:error, :infrastructure_unavailable}, state}
    end
  end

  defp ensure_machine(pool, name, root) do
    case inspect_machine(pool, name) do
      {:ok, _} = existing ->
        existing

      {:error, _} ->
        launch(pool, name, root)
        inspect_machine(pool, name)
    end
  end

  defp launch(pool, name, root) do
    docker(pool, [
      "run",
      "--detach",
      "--pull",
      "never",
      "--name",
      name,
      "--label",
      scope(pool),
      "--network",
      "none",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      "32",
      "--memory",
      "64m",
      "--log-driver",
      "none",
      "--mount",
      "type=bind,source=" <> root <> ",target=/workspace,readonly,bind-recursive=disabled",
      "--entrypoint",
      "/bin/sleep",
      pool.image,
      "2147483647"
    ])
  end

  def inspect_machine(pool, %{resource_id: id}), do: inspect_machine(pool, id)

  def inspect_machine(pool, name) do
    format =
      "{{.Id}} {{.State.Running}} {{.State.StartedAt}} {{index .Config.Labels \"#{@label}\"}}"

    tag = pool.tag

    with {output, 0} <- docker(pool, ["inspect", "--type", "container", "--format", format, name]),
         [id, running, started_at, ^tag] <- String.split(output) do
      {:ok, %{id: id, running: running == "true", started_at: started_at}}
    else
      _ ->
        {:error, :infrastructure_unavailable}
    end
  end

  def acquire(pool, %{id: lease_id, infrastructure: reference}, access) do
    resource_id = reference.resource_id

    Agent.get_and_update(pool.pid, fn state ->
      with false <- MapSet.member?(state.revoked, lease_id),
           {:ok, %{reference: ^reference} = machine} <- Map.fetch(state.machines, resource_id),
           :ok <- available(machine),
           {:ok, %{id: ^resource_id, running: true}} <- inspect_machine(pool, reference) do
        lease = %{id: lease_id, access: access}
        {{:ok, machine.reference}, put_in(state.machines[resource_id].lease, lease)}
      else
        true -> {{:error, :quiescence_unknown}, state}
        :error -> {{:error, :infrastructure_not_found}, state}
        {:error, _} = error -> {error, state}
        _ -> {{:error, :infrastructure_unavailable}, state}
      end
    end)
  end

  defp available(%{lease: nil}), do: :ok
  defp available(_), do: {:error, :infrastructure_busy}

  def release(pool, %{id: lease_id, infrastructure: %{resource_id: resource_id}}) do
    Agent.update(pool.pid, fn state ->
      state = %{state | revoked: MapSet.put(state.revoked, lease_id)}

      case state.machines[resource_id] do
        %{lease: %{id: ^lease_id}} -> put_in(state.machines[resource_id].lease, nil)
        _ -> state
      end
    end)
  end

  # Run file operations in the same service that grants and revokes leases.
  # A queued old request cannot mutate the tree after revocation.
  def with_lease({pool, resource_id, lease_id}, function) do
    Agent.get(pool.pid, fn state ->
      case state.machines[resource_id] do
        %{lease: %{id: ^lease_id}} = machine -> function.(machine)
        _ -> {:error, :quiescence_unknown}
      end
    end)
  end

  def docker(pool, args) do
    System.cmd(pool.docker, ["--host", pool.endpoint | args],
      env: [{"DOCKER_HOST", nil}, {"DOCKER_CONTEXT", nil}],
      stderr_to_stdout: true
    )
  end

  # Only the host fixture invokes this, after all Workspace handles close.
  def destroy(pool) do
    with {output, 0} <-
           docker(pool, ["ps", "--all", "--quiet", "--filter", "label=" <> scope(pool)]),
         :ok <- remove(pool, String.split(output)) do
      Agent.stop(pool.pid)
    else
      _ -> {:error, :cleanup_unconfirmed}
    end
  end

  defp remove(_, []), do: :ok

  defp remove(pool, ids) do
    case docker(pool, ["rm", "--force", "--volumes" | ids]) do
      {_, 0} -> :ok
      _ -> {:error, :cleanup_unconfirmed}
    end
  end

  def scope(pool), do: @label <> "=" <> pool.tag

  defp local_endpoint(docker) do
    endpoint =
      cond do
        System.get_env("DOCKER_CONTEXT", "") != "" ->
          inspect_context(docker, [System.fetch_env!("DOCKER_CONTEXT")])

        System.get_env("DOCKER_HOST", "") != "" ->
          {System.fetch_env!("DOCKER_HOST"), 0}

        true ->
          inspect_context(docker, [])
      end

    case endpoint do
      {"unix://" <> _ = host, 0} -> {:ok, String.trim(host)}
      _ -> {:error, :infrastructure_unavailable}
    end
  end

  defp inspect_context(docker, arguments) do
    System.cmd(
      docker,
      ["context", "inspect" | arguments] ++ ["--format", "{{.Endpoints.docker.Host}}"]
    )
  end
end
