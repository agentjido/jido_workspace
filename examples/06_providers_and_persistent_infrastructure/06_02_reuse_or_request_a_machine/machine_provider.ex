defmodule Jido.Workspace.Examples.MachineProvider do
  @moduledoc false
  @behaviour Jido.Workspace.Provider

  alias Jido.VFS.Capture
  alias Jido.Workspace.{Provider, Schemas}
  alias Jido.Workspace.Examples.MachinePool
  alias Jido.Workspace.Sandbox.Files

  @max_command_bytes 1_048_576

  @impl true
  def provision(
        %{infrastructure: reference} = lease,
        %{options: options, tree_access: access},
        nil
      ) do
    with {:ok, actual} <- MachinePool.acquire(options.pool, lease, access) do
      environment = {options.pool, reference.resource_id, lease.id}
      capabilities = %{tree_access: access, network: :disabled}
      {:ok, environment, capabilities, options[:reported] || actual}
    end
  end

  @impl true
  def release(lease, %{pool: pool}), do: MachinePool.release(pool, lease)

  @impl true
  def file(environment, request) do
    MachinePool.with_lease(environment, &file_request(&1, request))
  end

  defp file_request(%{lease: %{access: :read_only}}, request)
       when elem(request, 0) in [:write, :mkdir, :move, :delete, :check_write],
       do: {:error, :invalid_input}

  defp file_request(%{root: root}, {:read, path, :infinity}), do: Files.read(root, path)
  defp file_request(%{root: root}, {:read, path, limit}), do: Files.read(root, path, limit)

  defp file_request(%{root: root}, {:read, path, offset, count}),
    do: Files.read(root, path, offset, count)

  defp file_request(%{root: root}, {:write, path, bytes, :any}),
    do: Files.write_checked(root, path, bytes, :any) |> normalize()

  defp file_request(%{root: root}, {:write, path, bytes, {:revision, revision}}),
    do:
      Files.write_checked(root, path, bytes, &Provider.check_revision(&1, revision))
      |> normalize()

  defp file_request(%{root: root}, {:mkdir, path}),
    do: Files.mkdir(root, path, true) |> normalize()

  defp file_request(%{root: root}, {:delete, path}), do: Files.delete(root, path) |> normalize()

  defp file_request(%{root: root}, {:move, from, to}),
    do: Files.move(root, from, to) |> normalize()

  defp file_request(_, request), do: {:error, {:unsupported_capability, elem(request, 0)}}

  @impl true
  def run({pool, _, _} = environment, command) do
    with {:ok, {container, path}} <-
           MachinePool.with_lease(environment, &read_target(&1, command)) do
      case command.stop_reason.() do
        nil ->
          {bytes, status} = MachinePool.docker(pool, ["exec", container, "/bin/cat", "--", path])
          command.emit.(bytes)
          {:ok, command.stop_reason.() || {:exited, status}}

        stopped ->
          {:ok, stopped}
      end
    end
  end

  defp read_target(%{reference: reference}, %{argv: ["identity"], cwd: "."}),
    do: {:ok, {reference.resource_id, "/etc/hostname"}}

  defp read_target(machine, %{argv: ["read", name], cwd: cwd}) do
    path = if cwd == ".", do: name, else: cwd <> "/" <> name

    with true <- Schemas.relative_path?(name) and Schemas.relative_path?(path),
         {:ok, full} <- Files.path(machine.root, path),
         {:ok, %{type: :regular, size: size}} when size <= @max_command_bytes <- File.lstat(full) do
      {:ok, {machine.reference.resource_id, "/workspace/" <> path}}
    else
      _ -> {:error, :start_failed}
    end
  end

  defp read_target(_, _), do: {:error, :start_failed}

  @impl true
  def capture(environment, budget) do
    MachinePool.with_lease(environment, &capture_tree(&1.root, budget))
  end

  def capture_tree(root, budget) do
    with {:ok, entries} <- Files.capture(root, ".", true, {budget.entries, budget.bytes}),
         false <- Enum.any?(entries, &match?({_, %{type: :symlink}}, &1)) do
      {:ok, %Capture{entries: Map.new(entries, &portable/1)}}
    else
      true -> {:error, :unsupported_capability}
      error -> error
    end
  end

  defp portable({path, %{type: :directory}}), do: {path, %{type: :directory, metadata: %{}}}

  defp portable({path, %{bytes: bytes, mode: mode}}) do
    mode = if Bitwise.band(mode, 0o111) == 0, do: :regular, else: :executable
    {path, %{type: :file, content: bytes, metadata: %{mode: mode}}}
  end

  defp normalize({:error, :enoent}), do: {:error, :not_found}
  defp normalize({:error, :eexist}), do: {:error, :already_exists}
  defp normalize({:error, :enotdir}), do: {:error, :not_directory}
  defp normalize({:error, :eisdir}), do: {:error, :is_directory}
  defp normalize({:error, :enotempty}), do: {:error, :directory_not_empty}
  defp normalize(result), do: result
end
