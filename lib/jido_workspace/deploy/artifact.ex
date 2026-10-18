defmodule Jido.Workspace.Deploy.Artifact do
  @moduledoc "A versioned payload. Build and acceptance policy belong to the caller."
  @enforce_keys [:version, :kind, :snapshot]
  defstruct [:version, :kind, :snapshot]

  def new(kind, version, snapshot) when kind in [:otp, :source] do
    if is_binary(version) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, version) and
         Jido.Workspace.Deploy.Snapshot.valid?(snapshot) do
      {:ok, %__MODULE__{kind: kind, version: version, snapshot: snapshot}}
    else
      {:error, :invalid_artifact}
    end
  end

  def new(_, _, _), do: {:error, :invalid_artifact}

  def valid?(%__MODULE__{} = artifact) do
    match?({:ok, _}, new(artifact.kind, artifact.version, artifact.snapshot))
  end

  def valid?(_), do: false
end
