defmodule Jido.Workspace.TestSupport.ActionBoundary do
  @moduledoc "Test adapter for current APIs. See API_SPEC.md for proposed contracts."

  def schema(fields \\ %{}) do
    Zoi.object(Map.merge(%{request_id: Zoi.string(), resource_id: Zoi.string()}, fields))
  end

  def perform(params, context, kind, operation) do
    access = Map.fetch!(Map.get(context, :state, context), :workspace_access)

    result =
      case Map.fetch(access.resources, params.resource_id) do
        {:ok, {^kind, handle}} -> operation.(handle, access.store)
        _ -> {:error, :resource_not_found}
      end

    envelope = %{request_id: params.request_id, resource_id: params.resource_id}

    {suffix, envelope} =
      case result do
        {:ok, data} -> {"succeeded", Map.put(envelope, :result, data)}
        {:error, reason} -> {"failed", Map.put(envelope, :error, error_data(reason))}
      end

    if request = Map.get(context, :signal) do
      type = String.replace_suffix(request.type, "requested", suffix)

      reply =
        Jido.Signal.new!(type, Map.put(envelope, :causation_id, request.id),
          source: "/workspace/test-adapter"
        )

      :ok = Jido.Signal.Dispatch.dispatch(reply, {:pid, target: access.reply_to})
    end

    case result do
      {:ok, _} ->
        {:ok, envelope}

      {:error, reason} ->
        {:error,
         Jido.Action.Error.execution_error("Workspace request failed", %{domain_error: reason})}
    end
  end

  def put(store, resource_id, kind, value) do
    ref = "#{kind}-#{System.unique_integer([:positive, :monotonic])}"
    Agent.update(store, &Map.put(&1, ref, {resource_id, kind, value}))
    ref
  end

  def fetch(store, resource_id, kind, ref) do
    case Agent.get(store, &Map.get(&1, ref)) do
      {^resource_id, ^kind, value} -> {:ok, value}
      _ -> {:error, :resource_not_found}
    end
  end

  def execution_data(record, store, resource_id, expected) do
    record
    |> Map.take([:id, :command, :status, :exit_status, :output, :truncated, :duration_ms])
    |> Map.put(:checked_files, expected != :current and record.files == expected)
    |> Map.put(:file_view_ref, put(store, resource_id, :file_view, record.files))
    |> Map.put(
      :after_files,
      case record.after_files do
        {:error, reason} -> %{error: error_data(reason)}
        view -> %{file_view_ref: put(store, resource_id, :file_view, view)}
      end
    )
  end

  defp error_data({:policy_denied, action}),
    do: %{code: "policy_denied", action: to_string(action)}

  defp error_data(%Jido.Workspace.Error{} = error),
    do: %{
      code: to_string(error.code),
      operation: to_string(error.operation),
      resource: error.resource
    }

  defp error_data(%Jido.VFS.Errors.StaleState{}), do: %{code: "stale_revision"}
  defp error_data(:stale_file_view), do: %{code: "stale_file_view"}
  defp error_data(:resource_not_found), do: %{code: "resource_not_found"}
  defp error_data(reason), do: %{code: "operation_failed", cause: inspect(reason)}
end

defmodule Jido.Workspace.TestSupport.Actions.Write do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary

  use Jido.Action,
    name: "workspace_test_write",
    schema: Boundary.schema(%{path: Zoi.string(), content: Zoi.string()})

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, _store ->
      with :ok <- Jido.Workspace.write(ws, params.path, params.content),
           do: {:ok, %{path: params.path}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Mkdir do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  alias Jido.Workspace

  use Jido.Action,
    name: "workspace_file_test_mkdir",
    schema: Boundary.schema(%{path: Zoi.string()})

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, _store ->
      with :ok <- Workspace.mkdir(ws, params.path), do: {:ok, %{path: params.path}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Delete do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  alias Jido.Workspace

  use Jido.Action,
    name: "workspace_file_test_delete",
    schema: Boundary.schema(%{path: Zoi.string()})

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, _store ->
      with :ok <- Workspace.delete(ws, params.path), do: {:ok, %{path: params.path}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Close do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  alias Jido.Workspace
  use Jido.Action, name: "workspace_file_test_close", schema: Boundary.schema()

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, _store ->
      with :ok <- Workspace.close(ws), do: {:ok, %{closed: true}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Run do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary

  use Jido.Action,
    name: "workspace_test_run",
    schema:
      Boundary.schema(%{
        command: Zoi.string(),
        file_view_ref: Zoi.string() |> Zoi.optional(),
        timeout_ms: Zoi.integer() |> Zoi.default(30_000),
        output_limit: Zoi.integer() |> Zoi.default(1_048_576)
      })

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, store ->
      expected =
        case Map.get(params, :file_view_ref) do
          nil -> {:ok, :current}
          ref -> Boundary.fetch(store, params.resource_id, :file_view, ref)
        end

      with {:ok, view} <- expected do
        case Jido.Workspace.run(ws, params.command,
               files: view,
               timeout_ms: params.timeout_ms,
               output_limit: params.output_limit
             ) do
          {:ok, record} ->
            {:ok, Boundary.execution_data(record, store, params.resource_id, view)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Info do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  use Jido.Action, name: "workspace_test_info", schema: Boundary.schema()

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, _ ->
      with {:ok, info} <- Jido.Workspace.info(ws),
           do: {:ok, Map.take(info, [:id, :policy, :session])}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.List do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  use Jido.Action, name: "workspace_test_list", schema: Boundary.schema(%{path: Zoi.string()})

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, _ ->
      with {:ok, entries} <- Jido.Workspace.list(ws, params.path),
           do: {:ok, %{entries: Enum.map(entries, &Map.from_struct/1)}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.FileView do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  use Jido.Action, name: "workspace_test_file_view", schema: Boundary.schema()

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, store ->
      with {:ok, view} <- Jido.Workspace.file_view(ws),
           do: {:ok, %{file_view_ref: Boundary.put(store, params.resource_id, :file_view, view)}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.StartSession do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  use Jido.Action, name: "workspace_test_start_session", schema: Boundary.schema()

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, store ->
      with {:ok, session} <- Jido.Workspace.start_session(ws),
           do: {:ok, %{session_ref: Boundary.put(store, params.resource_id, :session, session)}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.StopSession do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  use Jido.Action, name: "workspace_test_stop_session", schema: Boundary.schema()

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, _ ->
      with :ok <- Jido.Workspace.stop_session(ws), do: {:ok, %{stopped: true}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Filesystem do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  use Jido.Action, name: "workspace_test_filesystem", schema: Boundary.schema()

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, store ->
      with {:ok, fs} <- Jido.Workspace.filesystem(ws),
           do: {:ok, %{filesystem_ref: Boundary.put(store, params.resource_id, :filesystem, fs)}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Shell do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  use Jido.Action, name: "workspace_test_shell", schema: Boundary.schema()

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, store ->
      with {:ok, session} <- Jido.Workspace.shell(ws),
           do: {:ok, %{session_ref: Boundary.put(store, params.resource_id, :session, session)}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Read do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  use Jido.Action, name: "workspace_test_read", schema: Boundary.schema(%{path: Zoi.string()})

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, _store ->
      with {:ok, content} <- Jido.Workspace.read(ws, params.path),
           do: {:ok, %{path: params.path, content: content}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Capture do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary
  use Jido.Action, name: "workspace_test_capture", schema: Boundary.schema()

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, store ->
      with {:ok, capture, revision} <- Jido.Workspace.capture(ws) do
        {:ok,
         %{
           capture_ref: Boundary.put(store, params.resource_id, :capture, capture),
           revision_ref: Boundary.put(store, params.resource_id, :revision, revision)
         }}
      end
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Replace do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary

  use Jido.Action,
    name: "workspace_test_replace",
    schema: Boundary.schema(%{capture_ref: Zoi.string(), revision_ref: Zoi.string()})

  def run(params, context) do
    Boundary.perform(params, context, :workspace, fn ws, store ->
      with {:ok, capture} <-
             Boundary.fetch(store, params.resource_id, :capture, params.capture_ref),
           {:ok, revision} <-
             Boundary.fetch(store, params.resource_id, :revision, params.revision_ref),
           {:ok, next} <- Jido.Workspace.replace(ws, capture, expected: revision) do
        {:ok, %{revision_ref: Boundary.put(store, params.resource_id, :revision, next)}}
      end
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Exec do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary

  use Jido.Action,
    name: "workspace_test_exec",
    schema: Boundary.schema(%{executable: Zoi.string(), args: Zoi.list(Zoi.string())})

  def run(params, context) do
    Boundary.perform(params, context, :sandbox, fn sandbox, _store ->
      with {:ok, execution} <-
             Jido.Workspace.Sandbox.exec(sandbox, params.executable, params.args) do
        {:ok, Map.take(execution, [:output, :exit_status, :truncated])}
      end
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Prepare do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary

  use Jido.Action,
    name: "workspace_test_prepare",
    schema: Boundary.schema(%{artifact_ref: Zoi.string()})

  def run(params, context) do
    Boundary.perform(params, context, :deployment, fn session, store ->
      with {:ok, artifact} <-
             Boundary.fetch(store, params.resource_id, :artifact, params.artifact_ref),
           {:ok, plan} <- Jido.Workspace.Deploy.prepare(session, artifact) do
        {:ok, %{plan_ref: Boundary.put(store, params.resource_id, :plan, plan)}}
      end
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Apply do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary

  use Jido.Action,
    name: "workspace_test_apply",
    schema: Boundary.schema(%{plan_ref: Zoi.string()})

  def run(params, context) do
    Boundary.perform(params, context, :deployment, fn session, store ->
      with {:ok, plan} <- Boundary.fetch(store, params.resource_id, :plan, params.plan_ref),
           {:ok, id} <- Jido.Workspace.Deploy.apply(session, plan),
           do: {:ok, %{operation_id: id}}
    end)
  end
end

defmodule Jido.Workspace.TestSupport.Actions.Await do
  alias Jido.Workspace.TestSupport.ActionBoundary, as: Boundary

  use Jido.Action,
    name: "workspace_test_await",
    schema: Boundary.schema(%{operation_id: Zoi.string()})

  def run(params, context) do
    Boundary.perform(params, context, :deployment, fn session, _store ->
      with {:ok, record} <- Jido.Workspace.Deploy.await(session, params.operation_id) do
        {:ok,
         %{
           operation_id: record.id,
           status: to_string(record.status),
           source_id: record.snapshot_id,
           digest: record.digest,
           step_count: length(record.steps),
           state_policy: to_string(record.evidence.state_policy)
         }}
      end
    end)
  end
end

defmodule Jido.Workspace.TestSupport.BoundaryAgent do
  @moduledoc "A fixed Jido Agent for API integration evidence. It does not use a model."
  alias Jido.Workspace.TestSupport.Actions

  use Jido.Agent,
    name: "workspace_boundary_test",
    schema: Zoi.object(%{workspace_access: Zoi.any()}),
    signal_routes: [
      {"jido.workspace.v1.workspace.write.requested", Actions.Write},
      {"jido.workspace.v1.workspace.read.requested", Actions.Read},
      {"jido.workspace.v1.workspace.mkdir.requested", Actions.Mkdir},
      {"jido.workspace.v1.workspace.delete.requested", Actions.Delete},
      {"jido.workspace.v1.workspace.close.requested", Actions.Close},
      {"jido.workspace.v1.workspace.run.requested", Actions.Run},
      {"jido.workspace.v1.workspace.info.requested", Actions.Info},
      {"jido.workspace.v1.workspace.list.requested", Actions.List},
      {"jido.workspace.v1.workspace.file_view.requested", Actions.FileView},
      {"jido.workspace.v1.workspace.start_session.requested", Actions.StartSession},
      {"jido.workspace.v1.workspace.stop_session.requested", Actions.StopSession},
      {"jido.workspace.v1.workspace.filesystem.requested", Actions.Filesystem},
      {"jido.workspace.v1.workspace.shell.requested", Actions.Shell},
      {"jido.workspace.v1.workspace.capture.requested", Actions.Capture},
      {"jido.workspace.v1.workspace.replace.requested", Actions.Replace},
      {"jido.workspace.v1.sandbox.exec.requested", Actions.Exec},
      {"jido.workspace.v1.deploy.prepare.requested", Actions.Prepare},
      {"jido.workspace.v1.deploy.apply.requested", Actions.Apply},
      {"jido.workspace.v1.deploy.await.requested", Actions.Await}
    ]

  # Effectful Actions must not use the executor's default retry count.
  @impl true
  def on_before_cmd(agent, action) do
    {:ok, instructions} = Jido.Instruction.normalize(action, %{}, max_retries: 0)
    {:ok, agent, instructions}
  end
end
