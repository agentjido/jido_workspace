defmodule Jido.Workspace.Examples.TransferFiles do
  alias Jido.Workspace

  @chunk_size 65_536

  def copy(workspace, source, destination) do
    chunks =
      Stream.unfold(0, fn offset ->
        case Workspace.read_chunk(workspace, source, offset, @chunk_size) do
          {:ok, ""} -> nil
          {:ok, bytes} -> {bytes, offset + byte_size(bytes)}
          {:error, error} -> raise "Source read failed (#{error.code})"
        end
      end)

    Workspace.write_stream(workspace, destination, chunks)
  end

  def checksum(workspace, path) do
    checksum(workspace, path, 0, :crypto.hash_init(:sha256))
  end

  defp checksum(workspace, path, offset, hash) do
    case Workspace.read_chunk(workspace, path, offset, @chunk_size) do
      {:ok, ""} ->
        {:ok, offset, :crypto.hash_final(hash)}

      {:ok, bytes} ->
        checksum(workspace, path, offset + byte_size(bytes), :crypto.hash_update(hash, bytes))

      {:error, _} = error ->
        error
    end
  end
end
