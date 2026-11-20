defmodule Jido.Workspace.Info do
  @moduledoc """
  Current controller information.

  Profiled workspaces report their phase and the ID of an active command.
  They also report per-command ceilings and the provider capabilities that
  Workspace recorded at open. The `:runtime_limits` capability lists the
  resource ceilings that the provider can enforce. An empty map means
  the provider reports no resource ceilings.
  A persistent workspace also reports its confirmed infrastructure reference.
  A provider can report `:lease_revoked` to fence a stale handle. The phase
  reflects the last result the controller received.
  A workspace opened without a profile reports its Shell session status.
  """
  @enforce_keys [:id, :policy, :owner, :session]
  defstruct [
    :id,
    :policy,
    :owner,
    :session,
    :phase,
    :active_execution_id,
    :infrastructure,
    :command_limits,
    :capabilities
  ]

  @type phase ::
          :ready
          | :running
          | :batching
          | :saving
          | :finding
          | :writing
          | :closing
          | :quiescence_unknown
          | :lease_revoked

  @type t :: %__MODULE__{
          id: String.t(),
          policy: Jido.Workspace.Policy.t(),
          owner: pid(),
          session: :running | :stopped,
          phase: phase() | nil,
          active_execution_id: String.t() | nil,
          infrastructure: Jido.Workspace.InfrastructureRef.t() | nil,
          command_limits: %{timeout_ms: pos_integer(), output_limit: non_neg_integer()} | nil,
          capabilities: %{required(:provider) => atom(), optional(atom()) => term()} | nil
        }
end
