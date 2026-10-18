defmodule Jido.Workspace.Sandbox.Files do
  @moduledoc false

  # Local provider implementation. All roots come from the Sandbox controller.
  @doc "Checks whether file names on the root filesystem are case sensitive."
  def case_sensitive?(root) do
    name = ".jido-case-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    path = Path.join(root, name)
    :ok = File.write(path, "", [:exclusive])

    try do
      not File.exists?(Path.join(root, String.upcase(name)))
    after
      File.rm(path)
    end
  end

  @doc "Resolves a path within the root and refuses symbolic link traversal."
  def path(root, relative) when is_binary(relative) do
    parts = Path.split(relative)

    if Path.type(relative) == :relative and relative != "" and
         Enum.all?(parts, &(&1 not in ["..", ""])) and not String.contains?(relative, <<0>>) do
      Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, parent} ->
        candidate = Path.join(parent, part)

        case File.lstat(candidate) do
          {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_path}}
          {:ok, stat} -> {:cont, {:ok, canonical_name(parent, part, stat)}}
          {:error, :enoent} -> {:cont, {:ok, candidate}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :invalid_path}
    end
  end

  def path(_, _), do: {:error, :invalid_path}

  # Resolve spelling aliases on a case-insensitive filesystem without following links.
  defp canonical_name(parent, ".", _), do: parent

  defp canonical_name(parent, part, stat) do
    case File.ls(parent) do
      {:ok, names} ->
        name =
          Enum.find(names, part, fn name ->
            case File.lstat(Path.join(parent, name)) do
              {:ok, other} ->
                {other.major_device, other.minor_device, other.inode} ==
                  {stat.major_device, stat.minor_device, stat.inode}

              _ ->
                false
            end
          end)

        Path.join(parent, name)

      _ ->
        Path.join(parent, part)
    end
  end

  @doc "Reads bytes from a checked path."
  def read(root, relative), do: with({:ok, path} <- path(root, relative), do: File.read(path))

  @doc "Creates a directory at a checked path."
  def mkdir(root, relative, parents) do
    with {:ok, path} <- path(root, relative) do
      if parents, do: File.mkdir_p(path), else: File.mkdir(path)
    end
  end

  @doc "Writes bytes and a supported file mode at a checked path."
  def write(root, relative, bytes, mode) when mode in [0o644, 0o755] do
    with {:ok, path} <- path(root, relative),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes),
         do: File.chmod(path, mode)
  end

  def write(_, _, _, _), do: {:error, :invalid_mode}

  @doc "Reads a link after checking its parent directory and leaf name."
  def read_link(root, relative) do
    with {:ok, parent} <- path(root, Path.dirname(relative)),
         :ok <- valid_leaf(relative),
         do: File.read_link(Path.join(parent, Path.basename(relative)))
  end

  @doc "Replaces a checked link with a relative destination through an atomic rename."
  def replace_link(root, relative, destination, nonce) do
    with :ok <- valid_leaf(relative),
         :ok <- valid_leaf(destination),
         :ok <- valid_leaf(nonce),
         true <- Path.basename(nonce) == nonce,
         {:ok, parent} <- path(root, Path.dirname(relative)),
         {:ok, _} <- path(root, Path.join(Path.dirname(relative), destination)),
         temporary = Path.join(parent, "." <> Path.basename(relative) <> "-" <> nonce),
         :ok <- File.ln_s(destination, temporary) do
      result = File.rename(temporary, Path.join(parent, Path.basename(relative)))
      if result != :ok, do: File.rm(temporary)
      result
    else
      false -> {:error, :invalid_path}
      error -> error
    end
  end

  defp valid_leaf(relative) do
    if is_binary(relative) and Path.type(relative) == :relative and
         Enum.all?(Path.split(relative), &(&1 not in ["..", ".", ""])) and
         not String.contains?(relative, <<0>>), do: :ok, else: {:error, :invalid_path}
  end

  @doc "Captures file entries below a checked directory. Links are optional."
  def capture(root, relative, links \\ false) do
    with {:ok, directory} <- path(root, relative), do: tree(directory, "", %{}, links)
  end

  defp tree(root, prefix, entries, links) do
    with {:ok, names} <- File.ls(Path.join(root, prefix)) do
      Enum.reduce_while(Enum.sort(names), {:ok, entries}, fn name, {:ok, acc} ->
        relative = if prefix == "", do: name, else: prefix <> "/" <> name
        full = Path.join(root, relative)

        result =
          with {:ok, stat} <- File.lstat(full) do
            case stat.type do
              :directory ->
                acc = if links, do: Map.put(acc, relative, %{type: :directory}), else: acc
                tree(root, relative, acc, links)

              :regular ->
                read_file(full, relative, stat, acc)

              :symlink when links ->
                with {:ok, target} <- File.read_link(full),
                     do: {:ok, Map.put(acc, relative, %{type: :symlink, target: target})}

              _ ->
                {:error, {:unsupported_file, relative}}
            end
          end

        case result do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp read_file(full, relative, stat, entries) do
    with {:ok, bytes} <- File.read(full) do
      mode = if Bitwise.band(stat.mode, 0o111) != 0, do: 0o755, else: 0o644
      {:ok, Map.put(entries, relative, %{bytes: bytes, mode: mode})}
    end
  end

  @doc "Checks captured content or only the supplied tracked entries."
  def verify(root, relative, entries, tracked) do
    if tracked do
      Enum.reduce_while(entries, :ok, fn {name, entry}, :ok ->
        result =
          with {:ok, full} <- path(root, Path.join(relative, name)),
               {:ok, %{type: :regular, mode: mode}} <- File.lstat(full),
               {:ok, bytes} <- File.read(full),
               true <-
                 bytes == entry.bytes and
                   if(Bitwise.band(mode, 0o111) != 0, do: 0o755, else: 0o644) == entry.mode,
               do: :ok

        if result == :ok, do: {:cont, :ok}, else: {:halt, {:error, {:source_changed, name}}}
      end)
    else
      case capture(root, relative) do
        {:ok, ^entries} -> :ok
        _ -> {:error, :content_mismatch}
      end
    end
  end
end
