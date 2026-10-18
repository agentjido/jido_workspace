defmodule Jido.Workspace.Info do
  @moduledoc "Current controller information. Session status does not grant raw access."
  @enforce_keys [:id, :policy, :owner, :session]
  defstruct [:id, :policy, :owner, :session]

  @type t :: %__MODULE__{
          id: String.t(),
          policy: atom(),
          owner: pid(),
          session: :running | :stopped
        }
end
