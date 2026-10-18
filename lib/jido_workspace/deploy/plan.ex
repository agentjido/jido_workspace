defmodule Jido.Workspace.Deploy.Plan do
  @moduledoc "An immutable transition proposal bound to one target observation."
  @enforce_keys [:id, :target, :artifact, :expected]
  defstruct [:id, :target, :artifact, :expected, :recipe, :preflight, :verify, :recovery_of]
end
