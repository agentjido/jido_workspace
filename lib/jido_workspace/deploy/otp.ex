defmodule Jido.Workspace.Deploy.OTP do
  import Kernel, except: [inspect: 1]

  @moduledoc """
  OTP release deployment through the target release handler.

  Payloads contain lib/App-Vsn and releases/Vsn/{Name.rel,start.boot,sys.config,relup}.
  This local spike uses the installed ERTS. It does not replace ERTS or make a
  release permanent. Failed installation can cause OTP to restart the target.
  """
  alias Jido.Workspace.Deploy.{Artifact, Snapshot, Target}
  alias Jido.Workspace.Sandbox

  def start(sandbox, name, %Artifact{kind: :otp} = artifact, opts \\ []) do
    path = Keyword.get(opts, :path, name)

    with :ok <- Sandbox.authorize(sandbox, :deploy),
         true <- Artifact.valid?(artifact),
         {:ok, location} <- Sandbox.location(sandbox, path),
         :ok <- Snapshot.project(artifact.snapshot, sandbox, location.path),
         {:ok, files} <- Sandbox.release_files(sandbox, location.path, artifact.version, true),
         {:ok, target} <- boot(location, name, files, opts) do
      {:ok, target}
    else
      false -> {:error, :digest_mismatch}
      error -> error
    end
  end

  defp boot(location, name, files, opts) do
    sandbox = location.sandbox
    path = location.path

    with {:ok, service} <-
           Sandbox.start_service(sandbox, %{
             kind: :beam,
             dir: path,
             args: files.args
           }) do
      target = %Target{
        id: location.id,
        name: name,
        sandbox: sandbox,
        kind: :otp,
        path: path,
        service: service,
        stage: Keyword.get(opts, :stage, :local),
        roles: Keyword.get(opts, :roles, [:app])
      }

      case call(target, :jido_workspace_deploy_target, :start, []) do
        {:ok, :ok} ->
          {:ok, target}

        error ->
          Sandbox.stop_service(sandbox, service)
          {:error, {:target_start, error}}
      end
    end
  end

  @doc "Reconnects target control after an OTP restart. It does not restore lost process state."
  def reconnect(%Target{kind: :otp} = target) do
    with {:ok, pid} when is_pid(pid) <- call(target, :erlang, :whereis, [:release_handler]),
         {:ok, releases} <- call(target, :release_handler, :which_releases, []),
         {:ok, applications} <- call(target, :application, :which_applications, []),
         true <- applications_ready?(releases, applications),
         {:ok, :ok} <- call(target, :jido_workspace_deploy_target, :start, []),
         {:ok, _} <- inspect(target) do
      {:ok, target}
    else
      error -> {:error, {:reconnect, error}}
    end
  end

  defp applications_ready?(releases, applications) do
    active =
      Enum.find(releases, fn {_, _, _, status} -> status == :current end) ||
        Enum.find(releases, fn {_, _, _, status} -> status == :permanent end)

    started = Enum.map(applications, fn {name, _, vsn} -> ~c"#{name}-#{vsn}" end)

    case active do
      {_, _, expected, _} -> Enum.all?(expected, &(&1 in started))
      _ -> false
    end
  end

  def inspect(target) do
    with {:ok, observation} <- call(target, :jido_workspace_deploy_target, :identity, []) do
      {:ok, %{identity: Map.take(observation, [:generation, :release]), runtime: observation}}
    end
  end

  defp stage(target, artifact, id) do
    with true <- Snapshot.valid?(artifact.snapshot),
         :ok <- Sandbox.mkdir(target.sandbox, "staging"),
         :ok <- Snapshot.project(artifact.snapshot, target.sandbox, "staging/" <> id),
         :ok <- merge_files(target, artifact.snapshot),
         {:ok, files} <- Sandbox.release_files(target.sandbox, target.path, artifact.version),
         :ok <- register_release(target, artifact.version, files.rel, files.apps) do
      :ok
    else
      false -> {:error, :digest_mismatch}
      error -> error
    end
  end

  defp register_release(target, version, rel, apps) do
    with {:ok, releases} <- call(target, :release_handler, :which_releases, []) do
      if Enum.any?(releases, fn {_, vsn, _, _} -> vsn == String.to_charlist(version) end) do
        :ok
      else
        case call(target, :release_handler, :set_unpacked, [String.to_charlist(rel), apps]) do
          {:ok, {:ok, _}} -> :ok
          other -> other
        end
      end
    end
  end

  def execute(target, plan, notify) do
    with :ok <- stage(target, plan.artifact, plan.id),
         _ <- notify.(:stage, :verified) do
      install(target, plan, notify)
    else
      error -> {:error, {:stage_failed, error}}
    end
  end

  defp install(target, plan, notify) do
    case call(target, :jido_workspace_deploy_target, :install, [
           plan.id,
           plan.expected,
           String.to_charlist(plan.artifact.version),
           plan.preflight,
           plan.recovery_of != nil
         ]) do
      {:ok, {:ok, id}} ->
        result = await(target, id, System.monotonic_time(:millisecond) + 30_000)
        notify.(:release_transition, result)

        case result do
          {:ok, evidence} -> verify(target, plan, evidence, notify)
          other -> other
        end

      {:ok, {:error, reason}} ->
        {:error, reason}

      error ->
        {:recovery_required, {:install_result_unknown, error}}
    end
  end

  defp verify(target, plan, evidence, notify) do
    expected_release = String.to_charlist(plan.artifact.version)

    result =
      with {:ok, observation} <- inspect(target),
           true <- observation.identity.release == expected_release,
           true <- observation.identity.generation == plan.expected.generation,
           :ok <- verify_callback(target, plan.verify) do
        {:ok, Map.put(evidence, :observation, observation)}
      else
        error -> {:recovery_required, {:verification_failed, error}}
      end

    notify.(:verify, result)
    result
  end

  defp verify_callback(_, nil), do: :ok

  defp verify_callback(target, {module, function, args}) do
    case call(target, module, function, args) do
      {:ok, :ok} -> :ok
      other -> {:error, other}
    end
  end

  defp await(target, id, deadline) do
    case call(target, :jido_workspace_deploy_target, :status, [id]) do
      {:ok, {:ok, %{status: :running}}} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          await(target, id, deadline)
        else
          {:recovery_required, :operation_timeout}
        end

      {:ok, {:ok, %{status: :succeeded} = evidence}} ->
        {:ok, evidence}

      {:ok, {:ok, %{status: :failed} = evidence}} ->
        {:error, evidence}

      {:ok, {:ok, evidence}} ->
        {:recovery_required, evidence}

      error ->
        {:recovery_required, {:target_unavailable, error}}
    end
  end

  def call(target, module, function, args),
    do: Sandbox.call(target.sandbox, target.service, module, function, args, 10_000)

  defp merge_files(target, snapshot) do
    Enum.reduce_while(Enum.sort(snapshot.entries), :ok, fn {path, entry}, :ok ->
      result =
        case Sandbox.read(target.sandbox, Path.join(target.path, path)) do
          {:ok, bytes} when bytes == entry.bytes ->
            :ok

          {:ok, _} ->
            {:error, {:immutable_file_conflict, path}}

          {:error, :enoent} ->
            Sandbox.write(target.sandbox, Path.join(target.path, path), entry.bytes, entry.mode)

          {:error, reason} ->
            {:error, reason}
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
