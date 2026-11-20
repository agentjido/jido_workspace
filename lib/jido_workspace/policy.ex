defmodule Jido.Workspace.Policy do
  @moduledoc """
  Workspace permissions for trusted tool callers.

  The controller stores the policy at creation. A caller cannot change it through
  a handle or a command option. These checks do not provide OS isolation.
  """
  @type preset :: :read_only | :workspace_write | :full_access
  @type action :: :read | :write | :execute | :import | :save | :recover
  @type t :: preset() | [action()]

  @profile_actions [:read, :write, :execute, :import, :save, :recover]
  @grants %{
    read_only: [:read, :import],
    workspace_write: [:read, :write, :import, :save],
    full_access: @profile_actions ++ [:deploy, :raw_handle]
  }
  @presets Map.keys(@grants)

  @doc "Checks a policy preset for the direct Workspace and Sandbox APIs."
  def validate(profile) when profile in @presets, do: :ok
  def validate(_), do: {:error, :invalid_policy}

  @doc false
  def schema do
    Zoi.union([
      Zoi.enum(@presets),
      Zoi.array(Zoi.enum(@profile_actions), unique_items: true)
    ])
  end

  @doc "Checks whether a policy permits the requested action."
  def authorize(policy, action) do
    if allows?(policy, action), do: :ok, else: {:error, {:policy_denied, action}}
  end

  @doc false
  def allows?(actions, action) when is_list(actions) do
    action in @profile_actions and action in actions
  end

  def allows?(preset, action), do: action in Map.get(@grants, preset, [])
end
