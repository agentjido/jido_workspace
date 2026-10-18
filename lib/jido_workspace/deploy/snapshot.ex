defmodule Jido.Workspace.Deploy.Snapshot do
  @moduledoc """
  A portable file payload. Source identity and content digest are separate.
  Paths are relative. Entries contain bytes and either regular or executable mode.
  Symlinks, device files, and parent traversal are refused.
  """
  @enforce_keys [:id, :digest, :entries]
  defstruct [:id, :digest, :entries]

  @type entry :: %{bytes: binary(), mode: 0o644 | 0o755}
  @type t :: %__MODULE__{id: term(), digest: String.t(), entries: %{String.t() => entry()}}

  @doc "Creates a snapshot from relative paths, bytes, and file modes. Conflicting paths are refused."
  def new(entries, opts \\ []) when is_map(entries) do
    valid =
      Enum.all?(entries, fn
        {path, %{bytes: bytes, mode: mode}} ->
          valid_path?(path) and is_binary(bytes) and mode in [0o644, 0o755]

        _ ->
          false
      end)

    paths = Map.keys(entries)

    conflicts =
      valid and
        Enum.any?(paths, fn path -> Enum.any?(paths, &String.starts_with?(&1, path <> "/")) end)

    if valid and not conflicts do
      normalized =
        Map.new(entries, fn {path, entry} -> {path, Map.take(entry, [:bytes, :mode])} end)

      digest = digest(normalized)
      {:ok, %__MODULE__{id: Keyword.get(opts, :id, digest), digest: digest, entries: normalized}}
    else
      {:error, :invalid_snapshot}
    end
  end

  @doc "Captures regular files from a directory. Symbolic links and special files are refused."
  def from_directory(directory, opts \\ []) do
    with {:ok, entries} <- read_tree(Path.expand(directory), "", %{}), do: new(entries, opts)
  end

  @doc "Checks snapshot paths, modes, and content digest."
  def valid?(%__MODULE__{entries: entries} = snapshot) when is_map(entries) do
    case new(snapshot.entries, id: snapshot.id) do
      {:ok, rebuilt} -> rebuilt.digest == snapshot.digest
      _ -> false
    end
  end

  def valid?(_), do: false

  @doc "Writes a valid snapshot into a new sandbox directory and checks the resulting files."
  def project(%__MODULE__{} = snapshot, sandbox, relative) do
    with :ok <- Jido.Workspace.Sandbox.authorize(sandbox, :write),
         true <- valid?(snapshot),
         :ok <- Jido.Workspace.Sandbox.mkdir(sandbox, relative, false) do
      result =
        Enum.reduce_while(Enum.sort(snapshot.entries), :ok, fn {path, entry}, :ok ->
          case Jido.Workspace.Sandbox.write(
                 sandbox,
                 Path.join(relative, path),
                 entry.bytes,
                 entry.mode
               ) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      case result do
        :ok -> Jido.Workspace.Sandbox.verify_files(sandbox, relative, snapshot.entries)
        error -> error
      end
    else
      false -> {:error, :digest_mismatch}
      error -> error
    end
  end

  @doc "Checks that a directory has exactly the snapshot content and file modes."
  def verify(snapshot, directory) do
    case from_directory(directory) do
      {:ok, %{digest: digest}} when digest == snapshot.digest -> :ok
      _ -> {:error, :content_mismatch}
    end
  end

  @doc "Checks a host-side directory. Use verify_tracked/3 for Sandbox files."
  def verify_tracked(snapshot, directory),
    do: Jido.Workspace.Sandbox.Files.verify(Path.expand(directory), ".", snapshot.entries, true)

  @doc "Checks captured files through Sandbox. Generated files are permitted."
  def verify_tracked(snapshot, sandbox, relative),
    do: Jido.Workspace.Sandbox.verify_files(sandbox, relative, snapshot.entries, true)

  @doc "Checks that a path is relative and has no empty, current, or parent components."
  def valid_path?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  def valid_path?(_), do: false

  defp digest(entries) do
    entries
    |> Enum.map(fn {path, entry} -> {path, entry.mode, entry.bytes} end)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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
