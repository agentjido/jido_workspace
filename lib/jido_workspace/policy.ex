defmodule Jido.Workspace.Policy do
  @moduledoc """
  Workspace permissions for trusted tool callers.

  The controller stores the policy at creation. A caller cannot change it through
  a handle or a command option. These checks do not provide OS isolation.
  """
  @profiles [:read_only, :workspace_write, :full_access]
  @actions [:read, :write, :execute, :deploy, :raw_handle]

  @doc "Checks that the policy profile is supported."
  def validate(profile) when profile in @profiles, do: :ok
  def validate(_), do: {:error, :invalid_policy}

  @doc "Checks whether a policy profile permits the requested action."
  def authorize(profile, action) do
    allowed =
      action in @actions and
        (profile == :full_access or
           (profile == :workspace_write and action in [:read, :write]) or
           (profile == :read_only and action == :read))

    if allowed, do: :ok, else: {:error, {:policy_denied, action}}
  end
end
