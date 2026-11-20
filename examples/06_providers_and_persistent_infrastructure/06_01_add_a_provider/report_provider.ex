defmodule Jido.Workspace.Examples.ReportProvider do
  @moduledoc false
  @behaviour Jido.Workspace.Provider
  use Agent

  alias Jido.VFS.Capture
  alias Jido.Workspace
  alias Jido.Workspace.{Error, Provider, Schemas}

  def start_link(_) do
    Agent.start_link(fn -> %{trees: %{}, revoked: MapSet.new(), retried: MapSet.new()} end)
  end

  def active_leases(registry), do: Agent.get(registry, &Map.keys(&1.trees))

  @impl true
  def provision(lease, %{options: options, tree_access: access}, capture) do
    if options[:hold_before_allocate] do
      notify(options, {:provision_waiting, lease})

      receive do
        {:resume_provision, id} when id == lease.id -> :ok
      after
        8_000 -> exit(:provision_wait_expired)
      end
    end

    result =
      Agent.get_and_update(options.registry, fn state ->
        allocate(state, lease.id, capture, access)
      end)

    case result do
      :ok ->
        notify(options, {:provisioned, lease})
        if secret = options[:raise_after_allocate], do: raise(secret)

        {:ok, {options.registry, lease.id},
         %{
           tree_access: options[:report_access] || access,
           isolation: :mediated,
           network: :disabled,
           cancellation: :cooperative
         }}

      {:error, _} = error ->
        notify(options, {:allocation_refused, lease.id})
        error
    end
  end

  defp allocate(state, id, capture, access) do
    if MapSet.member?(state.revoked, id) do
      {{:error, :closed}, state}
    else
      {:ok, tree} = Workspace.open(owner: self())

      case restore(tree, capture) do
        :ok ->
          {:ok, put_in(state.trees[id], %{tree: tree, access: access})}

        error ->
          Workspace.close(tree)
          {error, state}
      end
    end
  end

  defp restore(_, nil), do: :ok

  defp restore(tree, capture) do
    with {:ok, _, revision} <- Workspace.capture(tree),
         {:ok, _} <- Workspace.replace(tree, capture, expected: revision),
         do: :ok
  end

  @impl true
  def release(lease, options) do
    id = lease.id

    result =
      Agent.get_and_update(options.registry, fn state ->
        state = %{state | revoked: MapSet.put(state.revoked, id)}

        if options[:fail_release_once] == true and not MapSet.member?(state.retried, id) do
          {{:error, :cleanup_unconfirmed}, %{state | retried: MapSet.put(state.retried, id)}}
        else
          release_tree(state, id)
        end
      end)

    notify(options, {:release_result, id, result})
    result
  end

  defp release_tree(state, id) do
    case Map.pop(state.trees, id) do
      {nil, _} ->
        {:ok, state}

      {%{tree: tree}, remaining} ->
        case Workspace.close(tree) do
          :ok -> {:ok, %{state | trees: remaining}}
          {:error, _} -> {{:error, :cleanup_unconfirmed}, state}
        end
    end
  end

  @impl true
  def file(environment, request) do
    with_tree(environment, &file_request(&1, request))
  end

  defp file_request(%{access: :read_only}, request)
       when elem(request, 0) in [:write, :mkdir, :delete, :move, :check_write],
       do: {:error, :invalid_input}

  defp file_request(%{tree: tree}, {:read, path, limit}) do
    with {:ok, bytes} <- read(tree, path) do
      if limit == :infinity or byte_size(bytes) <= limit,
        do: {:ok, bytes},
        else: {:error, :discovery_byte_limit}
    end
  end

  defp file_request(%{tree: tree}, {:read, path, offset, count}) do
    with {:ok, bytes} <- read(tree, path) do
      offset = min(offset, byte_size(bytes))
      {:ok, binary_part(bytes, offset, min(count, byte_size(bytes) - offset))}
    end
  end

  defp file_request(%{tree: tree}, {:list, path, limit}) do
    with {:ok, entries} <- Workspace.list(tree, absolute(path)) |> normalize() do
      if limit == :infinity or length(entries) <= limit,
        do: {:ok, Enum.map(entries, &%{&1 | path: String.trim_leading(&1.path, "/")})},
        else: {:error, :discovery_entry_limit}
    end
  end

  defp file_request(%{tree: tree}, {:write, path, bytes, check}) do
    with :ok <- check_revision(tree, path, check) do
      tree |> Workspace.write(absolute(path), bytes) |> normalize()
    end
  end

  defp file_request(%{tree: tree}, {:mkdir, path}) do
    tree |> Workspace.mkdir(absolute(path)) |> normalize()
  end

  defp file_request(%{tree: tree}, {:check_write, path}) do
    case Workspace.list(tree, absolute(Path.dirname(path))) do
      {:ok, entries} ->
        if Enum.any?(entries, &(&1.kind == :directory and &1.path == absolute(path))),
          do: {:error, :is_directory},
          else: :ok

      {:error, %Error{code: :not_found}} ->
        :ok

      result ->
        normalize(result)
    end
  end

  defp file_request(_, request), do: {:error, {:unsupported_capability, elem(request, 0)}}

  defp check_revision(_, _, :any), do: :ok

  defp check_revision(tree, path, {:revision, expected}),
    do: Provider.check_revision(read(tree, path), expected)

  defp read(tree, path), do: tree |> Workspace.read(absolute(path)) |> normalize()

  @impl true
  def run(environment, %{argv: ["copy", source, destination]} = command) do
    with {:ok, source} <- command_path(command.cwd, source),
         {:ok, destination} <- command_path(command.cwd, destination),
         {:ok, _} <- file(environment, {:list, command.cwd, :infinity}),
         {:ok, bytes} <- file(environment, {:read, source, :infinity}),
         :ok <- file(environment, {:write, destination, bytes, :any}) do
      command.emit.("copied\n")
      {:ok, {:exited, 0}}
    else
      {:error, :quiescence_unknown} = error -> error
      _ -> {:ok, {:exited, 1}}
    end
  end

  def run(_, %{argv: ["wait"]} = command) do
    command.emit.("waiting\n")
    wait_for_stop(command.stop_reason)
  end

  def run(_, %{argv: ["missing-result"]}), do: {:error, :quiescence_unknown}
  def run(_, _), do: {:error, :start_failed}

  defp wait_for_stop(stop_reason) do
    case stop_reason.() do
      nil ->
        Process.sleep(5)
        wait_for_stop(stop_reason)

      stopped ->
        {:ok, stopped}
    end
  end

  defp command_path(cwd, path) do
    full = if cwd == ".", do: path, else: cwd <> "/" <> path

    if path != "." and Schemas.relative_path?(path) and Schemas.relative_path?(full),
      do: {:ok, full},
      else: {:error, :invalid_input}
  end

  @impl true
  def capture(environment, budget) do
    with_tree(environment, fn %{tree: tree} ->
      with {:ok, %Capture{entries: entries} = capture, _} <- Workspace.capture(tree),
           true <- map_size(entries) <= budget.entries,
           true <- Enum.reduce(entries, 0, &add_size/2) <= budget.bytes do
        {:ok, capture}
      else
        false -> {:error, :snapshot_too_large}
        result -> result
      end
    end)
  end

  defp add_size({_, %{content: bytes}}, total), do: total + byte_size(bytes)
  defp add_size(_, total), do: total

  defp with_tree({registry, id}, fun) do
    Agent.get(registry, fn state ->
      if MapSet.member?(state.revoked, id) or not Map.has_key?(state.trees, id),
        do: {:error, :quiescence_unknown},
        else: fun.(state.trees[id])
    end)
  end

  defp absolute("."), do: "/"
  defp absolute(path), do: "/" <> path

  defp normalize({:error, %Error{code: code}}), do: {:error, code}
  defp normalize(result), do: result

  defp notify(%{notify: pid}, message), do: send(pid, message)
  defp notify(_, _), do: :ok
end
