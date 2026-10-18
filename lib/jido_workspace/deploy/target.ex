defmodule Jido.Workspace.Deploy.Target do
  @moduledoc "A named deployment target. Its runtime belongs to Jido.Workspace.Sandbox."
  @enforce_keys [:name, :sandbox, :kind, :path]
  defstruct [:id, :name, :sandbox, :kind, :path, :service, stage: :local, roles: [:app]]

  @type t :: %__MODULE__{
          id: term(),
          name: String.t(),
          sandbox: Jido.Workspace.Sandbox.t(),
          kind: :otp | :source,
          path: String.t(),
          service: term(),
          stage: atom(),
          roles: [atom()]
        }
end
