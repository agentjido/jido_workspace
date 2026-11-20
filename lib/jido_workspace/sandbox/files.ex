defmodule Jido.Workspace.Sandbox.Files do
  @moduledoc false

  # Local provider implementation. All roots come from the Sandbox controller.
  def checkout_key(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory, major_device: major, minor_device: minor, inode: inode}} ->
        {:ok, "#{major}-#{minor}-#{inode}"}

      {:ok, %{type: :symlink}} ->
        {:error, :symlink_path}

      {:ok, _} ->
        {:error, :not_directory}

      error ->
        error
    end
  end

  def check_checkout(_, nil), do: :ok

  def check_checkout(root, key) do
    case checkout_key(root) do
      {:ok, ^key} -> :ok
      _ -> {:error, :checkout_changed}
    end
  end

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
  def path(root, relative, spelling \\ :canonical)

  def path(root, relative, spelling) when is_binary(relative) do
    parts = Path.split(relative)

    if Path.type(relative) == :relative and relative != "" and
         Enum.all?(parts, &(&1 not in ["..", ""])) and not String.contains?(relative, <<0>>) do
      Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, parent} ->
        candidate = Path.join(parent, part)

        case File.lstat(candidate) do
          {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_path}}
          {:ok, _} when spelling == :literal -> {:cont, {:ok, candidate}}
          {:ok, stat} -> {:cont, {:ok, canonical_name(parent, part, stat)}}
          {:error, :enoent} -> {:cont, {:ok, candidate}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :invalid_path}
    end
  end

  def path(_, _, _), do: {:error, :invalid_path}

  # Resolve spelling aliases on a case-insensitive filesystem without following links.
  defp canonical_name(parent, ".", _), do: parent

  defp canonical_name(parent, part, stat) do
    case File.ls(parent) do
      {:ok, names} ->
        name =
          if part in names do
            part
          else
            Enum.find(names, part, fn name ->
              case File.lstat(Path.join(parent, name)) do
                {:ok, other} ->
                  {other.major_device, other.minor_device, other.inode} ==
                    {stat.major_device, stat.minor_device, stat.inode}

                _ ->
                  false
              end
            end)
          end

        Path.join(parent, name)

      _ ->
        Path.join(parent, part)
    end
  end

  @doc "Reads bytes from a checked path."
  def read(root, relative) do
    with {:ok, path} <- path(root, relative, :literal),
         {:ok, _} <- regular_file(path),
         do: File.read(path)
  end

  def read(root, relative, limit) do
    with {:ok, path} <- path(root, relative, :literal),
         {:ok, %{size: size}} <- regular_file(path),
         true <- size <= limit do
      case File.open(path, [:read, :binary], &IO.binread(&1, size + 1)) do
        {:ok, :eof} when size == 0 -> {:ok, ""}
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) == size -> {:ok, bytes}
        {:ok, {:error, _} = error} -> error
        {:ok, _} -> {:error, :stale_file_view}
        {:error, _} = error -> error
      end
    else
      false -> {:error, :discovery_byte_limit}
      error -> error
    end
  end

  def read(root, relative, offset, count) do
    with {:ok, path} <- path(root, relative, :literal),
         {:ok, %{size: size}} <- regular_file(path) do
      if offset >= size do
        {:ok, ""}
      else
        case File.open(path, [:read, :binary, :raw], &:file.pread(&1, offset, count)) do
          {:ok, {:ok, bytes}} -> {:ok, bytes}
          {:ok, :eof} -> {:ok, ""}
          {:ok, {:error, _} = error} -> error
          {:error, _} = error -> error
        end
      end
    end
  end

  defp regular_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      {:ok, %{type: :directory}} -> {:error, :eisdir}
      {:ok, %{type: :symlink}} -> {:error, :symlink_path}
      {:ok, _} -> {:error, {:unsupported_capability, :file_type}}
      error -> error
    end
  end

  @doc "Creates a directory at a checked path."
  def mkdir(root, relative, parents) do
    with {:ok, path} <- path(root, relative) do
      if parents, do: File.mkdir_p(path), else: File.mkdir(path)
    end
  end

  @doc "Deletes a file or an empty directory."
  def delete(root, relative) do
    with {:ok, full} <- path(root, relative, :literal),
         true <- full != root,
         {:ok, stat} <- File.lstat(full) do
      if stat.type == :directory, do: remove_directory(full), else: File.rm(full)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp remove_directory(path) do
    case File.rmdir(path) do
      {:error, :eexist} -> {:error, :directory_not_empty}
      result -> result
    end
  end

  @doc "Moves a regular file or directory to an unused path."
  def move(root, source, destination) do
    with :ok <- valid_leaf(source),
         :ok <- valid_leaf(destination),
         {:ok, from} <- path(root, source, :literal),
         {:ok, to} <- path(root, destination, :literal),
         {:ok, %{type: type}} <- File.lstat(from),
         true <- type in [:regular, :directory],
         :ok <- vacant(to) do
      File.rename(from, to)
    else
      false -> {:error, {:unsupported_capability, :move_entry_type}}
      error -> error
    end
  end

  defp vacant(path) do
    case File.lstat(path) do
      {:ok, _} -> {:error, :eexist}
      {:error, :enoent} -> :ok
      error -> error
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

  def write_checked(root, relative, bytes, :any) do
    with {:ok, target} <- write_target(root, relative),
         {:ok, mode} <- write_mode(target),
         :ok <- File.mkdir_p(Path.dirname(target)),
         do: replace_file(target, bytes, mode)
  end

  def write_checked(root, relative, bytes, check) do
    with {:ok, target} <- write_target(root, relative),
         {:ok, stat} <- regular_file(target),
         :ok <- check.(File.read(target)) do
      replace_file(target, bytes, file_mode(stat))
    else
      {:error, :enoent} = missing -> check.(missing)
      error -> error
    end
  end

  def stage_write(root, relative) do
    with {:ok, target} <- write_target(root, relative),
         {:ok, mode} <- write_mode(target) do
      open_stage(target, mode)
    end
  end

  defp write_target(root, relative) do
    with :ok <- valid_leaf(relative), do: path(root, relative, :literal)
  end

  defp replace_file(target, bytes, mode) do
    with {:ok, stage} <- open_stage(target, mode) do
      try do
        with :ok <- append_stage(stage, bytes), do: commit_stage(stage)
      after
        discard_stage(stage)
      end
    end
  end

  defp write_mode(target) do
    case regular_file(target) do
      {:ok, stat} -> {:ok, file_mode(stat)}
      {:error, :enoent} -> {:ok, 0o644}
      error -> error
    end
  end

  defp file_mode(stat), do: Bitwise.band(stat.mode, 0o777)

  defp open_stage(target, mode) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    temporary = Path.join(Path.dirname(target), ".jido-write-" <> suffix)

    with {:ok, file} <- File.open(temporary, [:write, :binary, :raw, :exclusive]) do
      stage = %{file: file, temporary: temporary, target: target, mode: mode}

      case File.chmod(temporary, 0o600) do
        :ok ->
          {:ok, stage}

        error ->
          with :ok <- discard_stage(stage), do: error
      end
    end
  end

  def append_stage(stage, bytes), do: :file.write(stage.file, bytes)

  def commit_stage(stage) do
    with :ok <- File.close(stage.file),
         :ok <- File.chmod(stage.temporary, stage.mode),
         do: File.rename(stage.temporary, stage.target)
  end

  def discard_stage(stage) do
    File.close(stage.file)

    case File.rm(stage.temporary) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

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
  def capture(root, relative, links \\ false, budget \\ :unlimited) do
    with {:ok, directory} <- path(root, relative),
         {:ok, {entries, _budget}} <- tree(directory, "", {%{}, budget}, links),
         do: {:ok, entries}
  end

  defp tree(root, prefix, state, links) do
    with {:ok, names} <- File.ls(Path.join(root, prefix)) do
      Enum.reduce_while(Enum.sort(names), {:ok, state}, fn name, {:ok, {acc, budget}} ->
        relative = if prefix == "", do: name, else: prefix <> "/" <> name
        full = Path.join(root, relative)

        result =
          with {:ok, stat} <- File.lstat(full),
               {:ok, budget} <- reserve(budget, stat) do
            case stat.type do
              :directory ->
                acc = if links, do: Map.put(acc, relative, %{type: :directory}), else: acc
                tree(root, relative, {acc, budget}, links)

              :regular ->
                with {:ok, next} <- read_file(full, relative, stat, acc),
                     do: {:ok, {next, budget}}

              :symlink when links ->
                with {:ok, target} <- File.read_link(full),
                     do:
                       {:ok, {Map.put(acc, relative, %{type: :symlink, target: target}), budget}}

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

  defp reserve(:unlimited, _), do: {:ok, :unlimited}

  defp reserve({entries, bytes}, stat) do
    size = if stat.type == :regular, do: stat.size, else: 0

    if entries > 0 and size <= bytes,
      do: {:ok, {entries - 1, bytes - size}},
      else: {:error, :snapshot_too_large}
  end

  defp read_file(full, relative, stat, entries) do
    with {:ok, bytes} <- File.read(full) do
      mode = if Bitwise.band(stat.mode, 0o111) != 0, do: 0o755, else: 0o644
      {:ok, Map.put(entries, relative, %{bytes: bytes, mode: mode})}
    end
  end

  @doc "Checks captured content or only the supplied tracked entries."
  def verify(root, relative, entries, tracked, directories \\ nil) do
    entries =
      Enum.reduce(directories || [], entries, fn path, expected ->
        Map.put(expected, path, %{type: :directory})
      end)

    if tracked do
      Enum.reduce_while(entries, :ok, fn {name, entry}, :ok ->
        tracked_path = Path.join(relative, name)

        with {:ok, full} <- path(root, tracked_path),
             true <- is_nil(directories) or full == Path.expand(Path.join(root, tracked_path)),
             true <- matches?(full, entry) do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, {:source_changed, name}}}
        end
      end)
    else
      case capture(root, relative, not is_nil(directories)) do
        {:ok, ^entries} -> :ok
        _ -> {:error, :content_mismatch}
      end
    end
  end

  defp matches?(full, %{type: :directory}),
    do: match?({:ok, %{type: :directory}}, File.lstat(full))

  defp matches?(full, entry) do
    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(full),
         {:ok, bytes} <- File.read(full) do
      bytes == entry.bytes and
        if(Bitwise.band(mode, 0o111) != 0, do: 0o755, else: 0o644) == entry.mode
    end
  end
end
