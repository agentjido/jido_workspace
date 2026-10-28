defmodule SearchSpike.RealCorpus do
  @moduledoc false
  alias Jido.Workspace

  def freeze(source, destination) do
    walk(source, destination, "") |> Enum.sort_by(& &1.path)
  end

  defp walk(source, destination, relative) do
    File.ls!(Path.join(source, relative))
    |> Enum.flat_map(fn name ->
      path = Path.join(relative, name)
      full = Path.join(source, path)
      stat = File.lstat!(full)

      cond do
        name == ".git" or path == "_build" ->
          []

        stat.type == :directory ->
          walk(source, destination, path)

        stat.type != :regular ->
          []

        true ->
          data = File.read!(full)

          if String.valid?(data) and :binary.match(data, <<0>>) == :nomatch do
            target = Path.join(destination, path)
            File.mkdir_p!(Path.dirname(target))
            File.write!(target, data)
            [%{path: path, bytes: byte_size(data), sha256: hash(data)}]
          else
            []
          end
      end
    end)
  end

  def load(workspace, root, manifest) do
    manifest
    |> Enum.map(&Path.dirname(&1.path))
    |> Enum.uniq()
    |> Enum.sort_by(&{length(Path.split(&1)), &1})
    |> Enum.each(fn directory ->
      # VFS creates ancestor directories when needed.
      if directory != ".", do: match_ok!(Workspace.mkdir(workspace, "/" <> directory))
    end)

    Enum.each(manifest, fn item ->
      data = File.read!(Path.join(root, item.path))
      if hash(data) != item.sha256, do: raise("Corpus changed during load")
      match_ok!(Workspace.write(workspace, "/" <> item.path, data))
    end)
  end

  def hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp match_ok!(:ok), do: :ok
end
