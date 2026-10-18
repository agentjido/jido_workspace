defmodule Jido.Workspace.FileView do
  @moduledoc """
  The file source and revision observed before a command starts.

  A view is a precondition and an observation, not a lock on mutable storage.
  Workspace and Sandbox views cannot be used in place of each other.
  """
  @enforce_keys [:kind, :owner, :path, :revision]
  defstruct [:kind, :owner, :path, :revision]

  @type t :: %__MODULE__{kind: atom(), owner: term(), path: term(), revision: term()}

  def check(:current, %__MODULE__{}), do: :ok

  def check(%__MODULE__{revision: :unavailable}, _), do: {:error, :unversioned_file_view}

  def check(%__MODULE__{} = expected, %__MODULE__{} = actual) do
    if expected == actual, do: :ok, else: {:error, :stale_file_view}
  end

  def check(_, _), do: {:error, :invalid_file_view}

  def digest(entries) do
    entries
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
