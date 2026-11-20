defmodule Jido.Workspace.Entry do
  @moduledoc """
  A directory entry. Unknown mode or size is nil.

  Paths are relative on profiled workspaces and absolute on legacy workspaces.
  """
  @enforce_keys [:path, :kind]
  defstruct [:path, :kind, :mode, :size]

  @type t :: %__MODULE__{
          path: String.t(),
          kind: :file | :directory,
          mode: term(),
          size: non_neg_integer() | nil
        }
end
