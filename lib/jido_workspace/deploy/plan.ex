defmodule Jido.Workspace.Deploy.Plan do
  @moduledoc "An immutable transition proposal bound to one target observation."
  @enforce_keys [:id, :target, :artifact, :expected]
  defstruct [:id, :target, :artifact, :expected, :recipe, :preflight, :verify, :recovery_of]

  @type t :: %__MODULE__{
          id: String.t(),
          target: String.t(),
          artifact: Jido.Workspace.Deploy.Artifact.t(),
          expected: map(),
          recipe: Jido.Workspace.Deploy.Recipe.t() | nil,
          preflight: term(),
          verify: term(),
          recovery_of: String.t() | nil
        }
end
