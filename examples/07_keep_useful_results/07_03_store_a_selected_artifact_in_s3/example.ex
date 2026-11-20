defmodule Jido.Workspace.Examples.StoreS3Artifact do
  @moduledoc false

  alias Jido.VFS
  alias Jido.VFS.Adapter.S3
  alias Jido.VFS.Errors.AdapterError

  def put({S3, _} = destination, bytes) when is_binary(bytes) do
    digest = sha256(bytes)

    case VFS.write(destination, key(digest), bytes, if_none_match: "*") do
      :ok ->
        {:ok, digest}

      {:error, %AdapterError{adapter: S3, reason: {:http_error, 412, _}}} ->
        with {:ok, _bytes} <- fetch(destination, digest), do: {:ok, digest}

      {:error, _} = error ->
        error
    end
  end

  def fetch({S3, _} = destination, digest) when is_binary(digest) and byte_size(digest) == 64 do
    with {:ok, _} <- Base.decode16(digest, case: :lower),
         {:ok, bytes} <- VFS.read(destination, key(digest)) do
      if sha256(bytes) == digest, do: {:ok, bytes}, else: {:error, :artifact_digest_mismatch}
    else
      :error -> {:error, :invalid_artifact_digest}
      {:error, _} = error -> error
    end
  end

  def fetch({S3, _}, _), do: {:error, :invalid_artifact_digest}

  defp key(digest), do: "sha256/" <> digest
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
