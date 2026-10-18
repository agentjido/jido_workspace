defmodule Jido.Workspace.FileApiIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag capture_log: true

  alias Jido.Workspace
  alias Jido.Workspace.Error
  alias Jido.Workspace.TestSupport.{Actions, BoundaryAgent}

  setup do
    start_supervised!({Jido, name: __MODULE__.Runtime})
    {:ok, ws} = Workspace.open(policy: :workspace_write)
    {:ok, restricted} = Workspace.open(policy: :read_only)

    on_exit(fn ->
      Workspace.close(ws)
      Workspace.close(restricted)
    end)

    access = %{
      resources: %{"draft" => {:workspace, ws}, "readonly" => {:workspace, restricted}},
      store: nil,
      reply_to: self()
    }

    agent =
      start_supervised!(
        {Jido.AgentServer,
         jido: __MODULE__.Runtime,
         agent: BoundaryAgent,
         initial_state: %{workspace_access: access}}
      )

    %{ws: ws, restricted: restricted, access: access, agent: agent}
  end

  for mode <- [:direct, :action, :signal] do
    test "file lifecycle uses one stable handle through #{mode}", ctx do
      mode = unquote(mode)
      handle = ctx.ws

      assert {:ok, %{path: "/src"}} = call(mode, :mkdir, %{path: "/src"}, ctx)

      assert {:ok, %{path: "/src/input"}} =
               call(mode, :write, %{path: "/src/input", content: "first"}, ctx)

      assert {:ok, %{content: "first"}} = call(mode, :read, %{path: "/src/input"}, ctx)

      assert {:ok, %{path: "/src/input"}} =
               call(mode, :write, %{path: "/src/input", content: "second"}, ctx)

      assert {:ok, "second"} = Workspace.read(handle, "/src/input")

      assert {:ok, %{path: "/src/input"}} = call(mode, :delete, %{path: "/src/input"}, ctx)
      assert {:error, error} = call(mode, :read, %{path: "/src/input"}, ctx)
      assert error.code == :not_found
      assert error.operation == :read
      assert error.resource == handle.id

      assert {:ok, %{closed: true}} = call(mode, :close, %{}, ctx)
      assert {:ok, %{closed: true}} = call(mode, :close, %{}, ctx)
      assert {:error, error} = call(mode, :write, %{path: "/late", content: "bad"}, ctx)
      assert error.code == :closed
      assert ctx.ws == handle
      refute_receive {:signal, _}
    end

    test "policy errors have the same meaning through #{mode}", ctx do
      mode = unquote(mode)
      restricted = Map.merge(ctx, %{ws: ctx.restricted, resource_id: "readonly"})

      assert {:error, error} = call(mode, :write, %{path: "/blocked", content: "bad"}, restricted)
      assert error.code == :policy_denied
      assert error.operation == :write
      assert error.resource == ctx.restricted.id
      assert {:error, %Error{code: :not_found}} = Workspace.read(ctx.restricted, "/blocked")
      assert {:ok, %{closed: true}} = call(mode, :close, %{}, restricted)
      refute_receive {:signal, _}
    end
  end

  defp call(:direct, operation, params, ctx) do
    case operation do
      :read ->
        case Workspace.read(ctx.ws, params.path) do
          {:ok, content} -> {:ok, %{path: params.path, content: content}}
          {:error, error} -> {:error, error}
        end

      _ ->
        result =
          case operation do
            :mkdir -> Workspace.mkdir(ctx.ws, params.path)
            :write -> Workspace.write(ctx.ws, params.path, params.content)
            :delete -> Workspace.delete(ctx.ws, params.path)
            :close -> Workspace.close(ctx.ws)
          end

        case result do
          :ok -> {:ok, if(operation == :close, do: %{closed: true}, else: %{path: params.path})}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp call(:action, operation, params, ctx) do
    params = parameters(params, ctx)

    case Jido.Exec.run(action(operation), params, %{workspace_access: ctx.access}, max_retries: 0) do
      {:ok, %{result: data}} -> {:ok, data}
      {:error, %{details: %{domain_error: %Error{} = error}}} -> {:error, error}
    end
  end

  defp call(:signal, operation, params, ctx) do
    params = parameters(params, ctx)
    prefix = "jido.workspace.v1.workspace.#{operation}"
    request = Jido.Signal.new!(prefix <> ".requested", params, source: "/workspace/file-api-test")
    Jido.AgentServer.call(ctx.agent, request)
    request_id = params.request_id
    resource_id = params.resource_id
    causation_id = request.id

    assert_receive {:signal,
                    %Jido.Signal{
                      type: type,
                      data:
                        %{
                          request_id: ^request_id,
                          resource_id: ^resource_id,
                          causation_id: ^causation_id
                        } = data
                    }},
                   5_000

    assert {:ok, _} = Jason.encode(data)

    case data do
      %{result: result} ->
        assert type == prefix <> ".succeeded"
        {:ok, result}

      %{error: error} ->
        assert type == prefix <> ".failed"
        # The test accepts only known codes; it never creates atoms from Signal data.
        code = Enum.find([:not_found, :closed, :policy_denied], &(to_string(&1) == error.code))
        assert code
        assert error.operation == to_string(operation)
        {:error, %{code: code, operation: operation, resource: error.resource}}
    end
  end

  defp parameters(params, ctx) do
    Map.merge(params, %{
      request_id: "request-#{System.unique_integer([:positive, :monotonic])}",
      resource_id: Map.get(ctx, :resource_id, "draft")
    })
  end

  defp action(:write), do: Actions.Write
  defp action(:read), do: Actions.Read
  defp action(:mkdir), do: Actions.Mkdir
  defp action(:delete), do: Actions.Delete
  defp action(:close), do: Actions.Close
end
