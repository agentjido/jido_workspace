defmodule Jido.Workspace.Deploy.Source do
  @moduledoc "Source deployment with versioned directories and an atomic current link switch."
  alias Jido.Workspace.Deploy.{Recipe, Snapshot}
  alias Jido.Workspace.Sandbox

  def inspect(target) do
    with {:ok, _} <- Sandbox.location(target.sandbox, target.path) do
      current =
        case Sandbox.read_link(target.sandbox, Path.join(target.path, "current")) do
          {:ok, path} -> path
          {:error, :enoent} -> nil
          {:error, reason} -> {:error, reason}
        end

      service = read_service(target)
      runtime = if service, do: Sandbox.service_status(target.sandbox, service), else: nil

      {:ok,
       %{
         identity: %{current: current, service: service, status: service_state(runtime)},
         runtime: runtime
       }}
    end
  end

  def execute(target, plan, notify) do
    recipe = plan.recipe || %Recipe{}
    relative = Path.join([target.path, "releases", plan.id])

    with :ok <- Sandbox.mkdir(target.sandbox, Path.join(target.path, "releases")),
         :ok <- Snapshot.project(plan.artifact.snapshot, target.sandbox, relative),
         _ <- notify.(:stage, :verified),
         {:ok, preparation} <- commands(target, relative, recipe.prepare),
         :ok <- Snapshot.verify_tracked(plan.artifact.snapshot, target.sandbox, relative) do
      notify.(:prepare, preparation)
      activate(target, plan, relative, recipe, preparation, notify)
    else
      error -> {:error, %{phase: :prepare, reason: error}}
    end
  end

  defp activate(target, plan, relative, recipe, preparation, notify) do
    old_service = read_service(target)

    result =
      with :ok <- if(recipe.service, do: stop(target, old_service), else: :ok),
           :ok <-
             Sandbox.replace_link(
               target.sandbox,
               Path.join(target.path, "current"),
               "releases/" <> plan.id,
               plan.id
             ),
           {:ok, service} <-
             if(recipe.service,
               do: start(target, relative, recipe.service),
               else: {:ok, old_service}
             ),
           :ok <- save_service(target, service),
           _ <- notify.(:activate, %{service: service}),
           {:ok, verification} <- commands(target, relative, List.wrap(recipe.verify)) do
        notify.(:verify, verification)

        {:ok,
         %{
           phase: :verified,
           current: "releases/" <> plan.id,
           service: service,
           preparation: preparation,
           verification: verification,
           state_policy: if(recipe.service, do: :restart, else: :files_only)
         }}
      end

    case result do
      {:ok, _} = success -> success
      error -> {:recovery_required, %{phase: :activation_or_verification, reason: error}}
    end
  end

  defp commands(target, relative, commands) do
    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, results} ->
      {exe, args, opts} =
        case command do
          {exe, args} -> {exe, args, []}
          {exe, args, opts} -> {exe, args, opts}
        end

      case Sandbox.exec(target.sandbox, exe, args, Keyword.put(opts, :dir, relative)) do
        {:ok, %{status: :exited, exit_status: 0} = result} -> {:cont, {:ok, results ++ [result]}}
        error -> {:halt, {:error, {:command_failed, %{executable: exe, args: args}, error}}}
      end
    end)
  end

  defp start(target, relative, service),
    do: Sandbox.start_service(target.sandbox, Map.merge(service, %{kind: :exec, dir: relative}))

  defp stop(_, nil), do: :ok
  defp stop(target, service), do: Sandbox.stop_service(target.sandbox, service)

  defp read_service(target) do
    case Sandbox.read(target.sandbox, Path.join(target.path, ".service")) do
      {:ok, id} when byte_size(id) == 24 -> id
      _ -> nil
    end
  end

  defp save_service(target, nil),
    do: Sandbox.write(target.sandbox, Path.join(target.path, ".service"), "")

  defp save_service(target, id),
    do: Sandbox.write(target.sandbox, Path.join(target.path, ".service"), id)

  defp service_state({:ok, service}), do: {service.status, service.os_pid}
  defp service_state(other), do: other
end
