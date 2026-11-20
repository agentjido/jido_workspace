defmodule Jido.Workspace.Deploy.Snapshot do
  @moduledoc """
  A portable file payload. Source identity and content digest are separate.
  Paths are relative. Entries contain bytes and either regular or executable mode.
  Symlinks, device files, and parent traversal are refused.
  Payloads from saved Workspace references also preserve directory paths.
  """
  alias Jido.Workspace.{Policy, Profile, Sandbox, SnapshotStore}

  @enforce_keys [:id, :digest, :entries]
  defstruct [:id, :digest, :entries, :directories]

  @type entry :: %{bytes: binary(), mode: 0o644 | 0o755}
  @type t :: %__MODULE__{
          id: term(),
          digest: String.t(),
          entries: %{String.t() => entry()},
          directories: [String.t()] | nil
        }

  @doc "Creates a snapshot from relative paths, bytes, and file modes. Conflicting paths are refused."
  def new(entries, opts \\ []) when is_map(entries), do: build(entries, nil, opts)

  defp build(entries, directories, opts) do
    valid_files =
      Enum.all?(entries, fn
        {path, %{bytes: bytes, mode: mode}} ->
          valid_path?(path) and is_binary(bytes) and mode in [0o644, 0o755]

        _ ->
          false
      end)

    if valid_files and valid_layout?(entries, directories) do
      normalized =
        Map.new(entries, fn {path, entry} -> {path, Map.take(entry, [:bytes, :mode])} end)

      directories = if directories, do: Enum.sort(directories)
      digest = digest(normalized, directories)

      {:ok,
       %__MODULE__{
         id: Keyword.get(opts, :id, digest),
         digest: digest,
         entries: normalized,
         directories: directories
       }}
    else
      {:error, :invalid_snapshot}
    end
  end

  defp valid_layout?(entries, nil) do
    Enum.all?(Map.keys(entries), fn path -> no_file_parent?(Path.dirname(path), entries) end)
  end

  defp valid_layout?(entries, directories) when is_integer(length(directories)) do
    set = MapSet.new(directories)

    MapSet.size(set) == length(directories) and
      Enum.all?(directories, fn path ->
        valid_path?(path) and not Map.has_key?(entries, path) and directory_parent?(path, set)
      end) and
      Enum.all?(Map.keys(entries), &directory_parent?(&1, set))
  end

  defp valid_layout?(_, _), do: false

  defp directory_parent?(path, set) do
    parent = Path.dirname(path)
    parent == "." or MapSet.member?(set, parent)
  end

  defp no_file_parent?(".", _entries), do: true

  defp no_file_parent?(parent, entries),
    do: not Map.has_key?(entries, parent) and no_file_parent?(Path.dirname(parent), entries)

  @doc "Captures regular files from a directory. Symbolic links and special files are refused."
  def from_directory(directory, opts \\ []) do
    with {:ok, entries} <- read_tree(Path.expand(directory), "", %{}), do: new(entries, opts)
  end

  @doc """
  Resolves a saved Workspace reference with the named profile's read and import grants.

  The profile selects the store. No live workspace or runtime is opened. The
  payload records the validated reference as its source identity. Its own
  digest covers all file paths, bytes, file modes, and directory paths.
  """
  @spec from_saved(Jido.Workspace.Snapshot.t() | map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_saved(reference, profile: name) do
    with {:ok, profile} <- Profile.fetch(name),
         :ok <- Policy.authorize(profile.policy, :read),
         {:ok, reference, capture} <- SnapshotStore.fetch(profile, reference) do
      directories = for {path, %{type: :directory}} <- capture.entries, do: path
      build(file_entries(capture.entries), directories, id: reference)
    end
  end

  def from_saved(_, _), do: {:error, :invalid_input}

  @doc """
  Creates a deployment payload from a fixed VFS capture without reading live storage.

  Paths stay relative. Regular and executable modes become 0644 and 0755.
  Directories are validated but omitted, including empty directories. Other
  metadata is omitted. Invalid entries, paths, modes, and missing parents are
  refused. The optional `:id` is the caller's source identity, not a VFS revision.
  Without `:id`, the content digest is used, as in `new/2`.
  """
  @spec from_capture(Jido.VFS.Capture.t(), keyword()) :: {:ok, t()} | {:error, :invalid_capture}
  def from_capture(capture, opts \\ [])

  def from_capture(%Jido.VFS.Capture{entries: entries} = capture, opts) when is_map(entries) do
    with {:ok, entries} <- Jido.VFS.entries(capture),
         true <- Enum.all?(entries, &capture_entry?(&1, entries)) do
      new(file_entries(entries), opts)
    else
      _ -> {:error, :invalid_capture}
    end
  end

  def from_capture(_, _), do: {:error, :invalid_capture}

  defp file_entries(entries) do
    for {path, %{type: :file, content: bytes, metadata: meta}} <- entries, into: %{} do
      mode = if Map.get(meta, :mode, :regular) == :executable, do: 0o755, else: 0o644
      {path, %{bytes: bytes, mode: mode}}
    end
  end

  defp capture_entry?({path, entry}, entries) when is_binary(path) do
    valid_path?(path) and String.valid?(path) and capture_value?(entry) and
      capture_parent?(Path.dirname(path), entries)
  end

  defp capture_entry?(_, _), do: false

  defp capture_value?(%{type: :directory, metadata: meta}), do: is_map(meta)

  defp capture_value?(%{type: :file, content: bytes, metadata: meta})
       when is_binary(bytes) and is_map(meta),
       do: Map.get(meta, :mode, :regular) in [:regular, :executable]

  defp capture_value?(_), do: false

  defp capture_parent?(".", _), do: true

  defp capture_parent?(path, entries),
    do:
      match?(%{type: :directory}, entries[path]) and
        capture_parent?(Path.dirname(path), entries)

  @doc "Checks snapshot paths, modes, and content digest."
  def valid?(%__MODULE__{entries: entries} = snapshot) when is_map(entries) do
    case build(entries, Map.get(snapshot, :directories), id: snapshot.id) do
      {:ok, rebuilt} -> rebuilt.digest == snapshot.digest
      _ -> false
    end
  end

  def valid?(_), do: false

  @doc "Writes a valid snapshot into a new sandbox directory and checks the resulting files."
  def project(%__MODULE__{} = snapshot, sandbox, relative) do
    with :ok <- Sandbox.authorize(sandbox, :write),
         true <- valid?(snapshot),
         :ok <- Sandbox.mkdir(sandbox, relative, false),
         :ok <- ensure_directories(snapshot, sandbox, relative),
         :ok <- write_files(snapshot.entries, sandbox, relative) do
      Sandbox.verify_files(
        sandbox,
        relative,
        snapshot.entries,
        false,
        Map.get(snapshot, :directories)
      )
    else
      false -> {:error, :digest_mismatch}
      error -> error
    end
  end

  @doc false
  def ensure_directories(snapshot, sandbox, relative) do
    Enum.reduce_while(Map.get(snapshot, :directories) || [], :ok, fn path, :ok ->
      case Sandbox.mkdir(sandbox, Path.join(relative, path)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp write_files(entries, sandbox, relative) do
    Enum.reduce_while(Enum.sort(entries), :ok, fn {path, entry}, :ok ->
      case Sandbox.write(sandbox, Path.join(relative, path), entry.bytes, entry.mode) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Checks that a directory has exactly the snapshot content and file modes."
  def verify(%__MODULE__{directories: directories} = snapshot, directory)
      when is_list(directories) do
    if valid?(snapshot),
      do: Sandbox.Files.verify(Path.expand(directory), ".", snapshot.entries, false, directories),
      else: {:error, :content_mismatch}
  end

  def verify(snapshot, directory) do
    case from_directory(directory) do
      {:ok, %{digest: digest}} when digest == snapshot.digest -> :ok
      _ -> {:error, :content_mismatch}
    end
  end

  @doc "Checks tracked entries in a host-side directory. Use verify_tracked/3 for Sandbox files."
  def verify_tracked(snapshot, directory),
    do:
      Sandbox.Files.verify(
        Path.expand(directory),
        ".",
        snapshot.entries,
        true,
        Map.get(snapshot, :directories)
      )

  @doc "Checks tracked entries through Sandbox. Generated files and directories are permitted."
  def verify_tracked(snapshot, sandbox, relative),
    do:
      Sandbox.verify_files(
        sandbox,
        relative,
        snapshot.entries,
        true,
        Map.get(snapshot, :directories)
      )

  @doc "Checks that a path is relative and has no empty, current, or parent components."
  def valid_path?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  def valid_path?(_), do: false

  defp digest(entries, directories) do
    files =
      entries |> Enum.map(fn {path, entry} -> {path, entry.mode, entry.bytes} end) |> Enum.sort()

    contents = if directories, do: {files, directories}, else: files
    Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(contents)), case: :lower)
  end

  defp read_tree(root, prefix, entries) do
    with {:ok, names} <- File.ls(Path.join(root, prefix)) do
      Enum.reduce_while(Enum.sort(names), {:ok, entries}, fn name, {:ok, acc} ->
        path = if prefix == "", do: name, else: prefix <> "/" <> name

        result =
          with {:ok, stat} <- File.lstat(Path.join(root, path)) do
            case stat.type do
              :directory ->
                read_tree(root, path, acc)

              :regular ->
                read_file(root, path, stat, acc)

              _ ->
                {:error, {:unsupported_file, path}}
            end
          end

        case result do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp read_file(root, path, stat, entries) do
    with {:ok, bytes} <- File.read(Path.join(root, path)) do
      mode = if Bitwise.band(stat.mode, 0o111) != 0, do: 0o755, else: 0o644
      {:ok, Map.put(entries, path, %{bytes: bytes, mode: mode})}
    end
  end
end
