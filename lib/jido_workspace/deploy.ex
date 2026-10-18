defmodule Jido.Workspace.Deploy do
  @moduledoc """
  Explicit deployment recipes for named targets.

  OTP releases and source snapshots share planning, operation identity, status,
  and recovery. Workspace policy controls deployment. Acceptance belongs to the calling application.
  Results stay in controller memory. A lost controller requires runtime inspection.
  """
  alias Jido.Workspace.Deploy.{Artifact, Server, Target}

  @doc "Connects to the controller for a target. Conflicting target definitions are refused."
  def connect(%Target{} = target) do
    with {:ok, location} <- Jido.Workspace.Sandbox.location(target.sandbox, target.path) do
      canonical = %{target | id: location.id, path: location.path, sandbox: location.sandbox}

      case DynamicSupervisor.start_child(
             Jido.Workspace.Deploy.Supervisor,
             {Server, {location.id, canonical}}
           ) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          if GenServer.call(pid, :target) == canonical,
            do: {:ok, pid},
            else: {:error, :target_conflict}

        error ->
          error
      end
    end
  end

  @doc "Creates a source target and its shared directory in the sandbox."
  def source_target(sandbox, name, opts \\ []) do
    path = Keyword.get(opts, :path, name)

    with :ok <- Jido.Workspace.Sandbox.authorize(sandbox, :deploy),
         {:ok, location} <- Jido.Workspace.Sandbox.location(sandbox, path),
         :ok <- Jido.Workspace.Sandbox.mkdir(sandbox, location.path),
         :ok <- Jido.Workspace.Sandbox.mkdir(sandbox, Path.join(location.path, "shared")) do
      {:ok,
       %Target{
         id: location.id,
         name: name,
         sandbox: location.sandbox,
         kind: :source,
         path: location.path,
         stage: Keyword.get(opts, :stage, :local),
         roles: Keyword.get(opts, :roles, [:app])
       }}
    end
  end

  @doc "Reads the current target identity and runtime state."
  def inspect(session), do: GenServer.call(session, :inspect)

  @doc "Creates a plan bound to the current target observation. It does not apply the plan."
  def prepare(session, %Artifact{} = artifact, opts \\ []),
    do: GenServer.call(session, {:prepare, artifact, opts}, 15_000)

  @doc "Starts the supplied plan after its target preconditions pass."
  def apply(session, plan), do: GenServer.call(session, {:apply, plan})
  @doc "Reads the recorded status and evidence for an operation."
  def status(session, id), do: GenServer.call(session, {:status, id})

  @doc "Prepares a new explicit transition after a failed or successful deployment."
  def recover(session, operation_id, %Artifact{} = artifact, opts \\ []) do
    GenServer.call(session, {:recover, operation_id, artifact, opts}, 15_000)
  end

  @doc "Waits for an operation. A timeout does not cancel execution."
  def await(session, id, timeout \\ 30_000),
    do: wait(session, id, System.monotonic_time(:millisecond) + timeout)

  defp wait(session, id, deadline) do
    case status(session, id) do
      {:ok, %{status: :running}} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          wait(session, id, deadline)
        else
          {:error, {:timeout, id}}
        end

      result ->
        result
    end
  end
end
