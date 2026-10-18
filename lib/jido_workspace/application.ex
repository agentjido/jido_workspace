defmodule Jido.Workspace.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    Supervisor.start_link(
      [
        {Registry, keys: :unique, name: Jido.Workspace.Sandbox.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Jido.Workspace.Sandbox.Supervisor},
        {Registry, keys: :unique, name: Jido.Workspace.Deploy.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Jido.Workspace.Deploy.Supervisor},
        {Task.Supervisor, name: Jido.Workspace.Deploy.Tasks}
      ],
      strategy: :one_for_one,
      name: Jido.Workspace.Supervisor
    )
  end
end
