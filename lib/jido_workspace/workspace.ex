defmodule Jido.Workspace.Workspace do
  @moduledoc "A stable handle for one Workspace controller generation."
  @opaque t :: %__MODULE__{id: String.t(), lifetime: pid()}
  @enforce_keys [:id, :lifetime]
  defstruct [:id, :lifetime]
end
