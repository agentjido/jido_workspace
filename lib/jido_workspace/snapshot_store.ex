defmodule Jido.Workspace.SnapshotStore do
  @moduledoc false

  alias Jido.VFS.Capture
  alias Jido.Workspace.{Schemas, Snapshot}

  @max_entries 10_000
  @max_bytes 16 * 1024 * 1024
  @max_bundle 24 * 1024 * 1024

  def capture_budget, do: {@max_entries, @max_bytes}

  def put(store, %Capture{entries: entries}) when is_binary(store) do
    with {:ok, root} <- root(store),
         :ok <- validate(entries),
         {:ok, bytes} <- encode(entries),
         {:ok, reference} <- Snapshot.new(store, digest(bytes)),
         :ok <- File.mkdir_p(root),
         :ok <- publish(root, reference.digest, bytes) do
      {:ok, reference}
    end
  end

  def put(_, _), do: {:error, :snapshot_store_unconfigured}

  def fetch(store, snapshot) do
    with {:ok, reference} <- parse(snapshot),
         :ok <- authorize_store(store, reference.store),
         {:ok, root} <- root(store),
         {:ok, bytes} <- read_bundle(Path.join(root, reference.digest)),
         true <- digest(bytes) == reference.digest,
         {:ok, capture} <- decode(bytes) do
      {:ok, capture}
    else
      false -> {:error, :invalid_snapshot}
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  defp parse(value) do
    case Snapshot.parse(value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :invalid_snapshot}
    end
  end

  defp authorize_store(store, store) when is_binary(store), do: :ok
  defp authorize_store(_, _), do: {:error, {:policy_denied, :import}}

  defp root(store) do
    stores = Application.get_env(:jido_workspace, :stores, %{})

    case is_map(stores) && Map.get(stores, store) do
      root when is_binary(root) and byte_size(root) > 0 -> {:ok, Path.expand(root)}
      _ -> {:error, :snapshot_store_unconfigured}
    end
  end

  defp encode(entries) do
    entries
    |> Enum.sort()
    |> Enum.map(fn
      {path, %{type: :directory}} ->
        [path, "dir"]

      {path, %{type: :file, content: bytes, metadata: meta}} ->
        mode = if Map.get(meta, :mode) == :executable, do: "executable", else: "regular"
        [path, mode, Base.encode64(bytes)]
    end)
    |> Jason.encode()
    |> case do
      {:ok, bytes} when byte_size(bytes) <= @max_bundle -> {:ok, bytes}
      _ -> {:error, :snapshot_too_large}
    end
  end

  defp decode(bundle) do
    with {:ok, rows} when is_list(rows) <- Jason.decode(bundle),
         true <- length(rows) <= @max_entries,
         {:ok, entries} <- decode_rows(rows),
         :ok <- validate(entries) do
      {:ok, %Capture{entries: entries}}
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp decode_rows(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, entries} ->
      with {:ok, path, entry} <- decode_row(row),
           false <- Map.has_key?(entries, path) do
        {:cont, {:ok, Map.put(entries, path, entry)}}
      else
        _ -> {:halt, {:error, :invalid_snapshot}}
      end
    end)
  end

  defp decode_row([path, "dir"]), do: {:ok, path, %{type: :directory, metadata: %{}}}

  defp decode_row([path, mode, content])
       when mode in ["regular", "executable"] and is_binary(content) do
    with {:ok, bytes} <- Base.decode64(content) do
      mode = if mode == "executable", do: :executable, else: :regular
      {:ok, path, %{type: :file, content: bytes, metadata: %{mode: mode}}}
    end
  end

  defp decode_row(_), do: {:error, :invalid_snapshot}

  defp validate(entries) when map_size(entries) <= @max_entries do
    Enum.reduce_while(entries, 0, fn {path, entry}, total ->
      with true <- path != "." and Schemas.relative_path?(path),
           true <- directory_parent?(entries, Path.dirname(path)),
           {:ok, size} <- entry_size(entry) do
        if total + size <= @max_bytes,
          do: {:cont, total + size},
          else: {:halt, {:error, :snapshot_too_large}}
      else
        _ -> {:halt, {:error, :invalid_snapshot}}
      end
    end)
    |> case do
      total when is_integer(total) -> :ok
      error -> error
    end
  end

  defp validate(_), do: {:error, :snapshot_too_large}

  defp directory_parent?(_, "."), do: true
  defp directory_parent?(entries, path), do: match?(%{type: :directory}, entries[path])

  defp entry_size(%{type: :directory, metadata: meta}) when is_map(meta), do: {:ok, 0}

  defp entry_size(%{type: :file, content: bytes, metadata: meta})
       when is_binary(bytes) and is_map(meta) do
    if Map.get(meta, :mode, :regular) in [:regular, :executable],
      do: {:ok, byte_size(bytes)},
      else: :error
  end

  defp entry_size(_), do: :error

  defp publish(root, digest, bytes) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    temporary = Path.join(root, ".pending-" <> nonce)

    case File.open(temporary, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        try do
          result = IO.binwrite(device, bytes)
          closed = File.close(device)

          with :ok <- result, :ok <- closed do
            File.rename(temporary, Path.join(root, digest))
          end
        after
          File.rm(temporary)
        end

      error ->
        error
    end
  end

  defp read_bundle(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_bundle + 1)) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @max_bundle -> {:ok, bytes}
      {:ok, _} -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
