defmodule Jido.Workspace.Application do
  @moduledoc false
  use Application

  @doc "Starts the Workspace controller supervisors and registries."
  def start(_, _) do
    Supervisor.start_link(
      [
        %{
          id: Jido.VFS.Application,
          type: :supervisor,
          start: {Jido.VFS.Application, :start, [:normal, []]}
        },
        %{
          id: Jido.Shell.Application,
          type: :supervisor,
          start: {Jido.Shell.Application, :start, [:normal, []]}
        },
        {Registry, keys: :unique, name: Jido.Workspace.Sandbox.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Jido.Workspace.Sandbox.Supervisor},
        {Task.Supervisor, name: Jido.Workspace.ProfileSession.Tasks},
        {DynamicSupervisor,
         strategy: :one_for_one, name: Jido.Workspace.ProfileSession.Supervisor},
        {Registry, keys: :unique, name: Jido.Workspace.Deploy.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Jido.Workspace.Deploy.Supervisor},
        {Task.Supervisor, name: Jido.Workspace.Deploy.Tasks}
      ],
      strategy: :one_for_one,
      name: Jido.Workspace.Supervisor
    )
  end
end
