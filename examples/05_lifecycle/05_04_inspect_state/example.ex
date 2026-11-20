defmodule Jido.Workspace.Examples.ObserveCommand do
  @moduledoc "Forward command events for one workspace to the caller."

  alias Jido.Workspace

  @events [[:jido_workspace, :command, :start], [:jido_workspace, :command, :stop]]

  def attach(workspace) do
    handler = {__MODULE__, make_ref()}

    with {:ok, %{id: workspace_id}} <- Workspace.info(workspace),
         :ok <-
           :telemetry.attach_many(
             handler,
             @events,
             &__MODULE__.forward/4,
             {self(), workspace_id}
           ) do
      {:ok, handler}
    end
  end

  @doc false
  def forward(
        [:jido_workspace, :command, event],
        measures,
        %{workspace_id: id} = data,
        {pid, id}
      ),
      do: send(pid, {:workspace_command, event, measures, data})

  def forward(_, _, _, _), do: :ok
end
