defmodule Jido.Workspace.ContractIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag capture_log: true
  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.TestSupport.{ActionBoundary, Actions, BoundaryAgent, ProcessBackend}

  setup do
    start_supervised!({Jido, name: __MODULE__.Runtime})
    store = start_supervised!({Agent, fn -> %{} end})
    {:ok, ws} = Workspace.open()
    {:ok, restricted} = Workspace.open(policy: :read_only)

    on_exit(fn ->
      Workspace.close(ws)
      Workspace.close(restricted)
    end)

    access = %{
      store: store,
      reply_to: self(),
      resources: %{"draft" => {:workspace, ws}, "readonly" => {:workspace, restricted}}
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
    test "entries, captures, and checked replacement through #{mode}", ctx do
      mode = unquote(mode)
      :ok = Workspace.mkdir(ctx.ws, "/empty")
      :ok = Workspace.write(ctx.ws, "/input", "first")
      assert {:ok, %{id: id, session: :stopped}} = call(mode, :info, %{}, ctx)
      assert id == ctx.ws.id

      assert {:ok,
              %{
                entries: [
                  %{path: "/empty", kind: :directory},
                  %{path: "/input", kind: :file, size: 5}
                ]
              }} =
               call(mode, :list, %{path: "/"}, ctx)

      {:ok, saved} = call(mode, :capture, %{}, ctx)
      :ok = Workspace.write(ctx.ws, "/input", "second")

      assert {:error, %{code: "stale_revision", operation: "replace"}} =
               call(mode, :replace, saved, ctx)

      assert {:ok, "second"} = Workspace.read(ctx.ws, "/input")
      {:ok, current} = call(mode, :capture, %{}, ctx)

      assert {:ok, %{revision_ref: _}} =
               call(mode, :replace, %{saved | revision_ref: current.revision_ref}, ctx)

      assert {:ok, "first"} = Workspace.read(ctx.ws, "/input")

      {:ok, capture} =
        ActionBoundary.fetch(ctx.access.store, "draft", :capture, saved.capture_ref)

      :ok = Workspace.close(ctx.ws)
      assert {:ok, "first"} = Jido.VFS.read(capture, "input")
      assert {:error, %{code: "closed", operation: "info"}} = call(mode, :info, %{}, ctx)
      assert {:error, %{code: "closed", operation: "capture"}} = call(mode, :capture, %{}, ctx)
      refute_receive {:signal, _}
    end

    test "command evidence, output limits, timeout, and session state through #{mode}", ctx do
      mode = unquote(mode)
      {:ok, pinned} = call(mode, :file_view, %{}, ctx)

      assert {:ok, %{status: :exited, exit_status: 0, checked_files: true}} =
               call(mode, :run, Map.merge(pinned, %{command: "write /input first"}), ctx)

      assert {:ok, %{session: :running}} = call(mode, :info, %{}, ctx)

      assert {:error, %{code: "stale_file_view"}} =
               call(mode, :run, Map.merge(pinned, %{command: "write /marker bad"}), ctx)

      assert {:error, %Error{code: :not_found}} = Workspace.read(ctx.ws, "/marker")

      assert {:ok, %{output: "abc", truncated: true, status: :exited}} =
               call(mode, :run, %{command: "echo abcdef", output_limit: 3}, ctx)

      assert {:ok, %{output: "", truncated: true}} =
               call(mode, :run, %{command: "echo abcdef", output_limit: 0}, ctx)

      assert {:ok, %{status: :timed_out, exit_status: nil}} =
               call(mode, :run, %{command: "seq 20 10; write /late bad", timeout_ms: 30}, ctx)

      assert {:ok, %{output: "ready\n", status: :exited}} =
               call(mode, :run, %{command: "echo ready"}, ctx)

      assert {:error, %Error{code: :not_found}} = Workspace.read(ctx.ws, "/late")
      assert {:ok, %{stopped: true}} = call(mode, :stop_session, %{}, ctx)
      assert {:ok, %{stopped: true}} = call(mode, :stop_session, %{}, ctx)
      assert {:ok, %{session: :stopped}} = call(mode, :info, %{}, ctx)
      assert Map.keys(Map.from_struct(ctx.ws)) |> Enum.sort() == [:id, :lifetime]
      refute_receive {:signal, _}
    end

    test "raw access, policy refusal, and invalid input through #{mode}", ctx do
      mode = unquote(mode)
      assert {:ok, %{session_ref: _}} = call(mode, :start_session, %{}, ctx)
      assert {:ok, %{session_ref: _}} = call(mode, :shell, %{}, ctx)
      assert {:ok, %{filesystem_ref: _}} = call(mode, :filesystem, %{}, ctx)

      for operation <- [:start_session, :shell, :filesystem, :run] do
        params = if operation == :run, do: %{command: "write /blocked bad"}, else: %{}

        assert {:error, %{code: "policy_denied"}} =
                 call(
                   mode,
                   operation,
                   params,
                   %{ctx | ws: ctx.restricted} |> Map.put(:resource_id, "readonly")
                 )
      end

      assert {:error, %{code: "invalid_input"}} = call(mode, :list, %{path: "/../bad"}, ctx)
      assert {:error, %{code: "invalid_input"}} = call(mode, :run, %{command: " "}, ctx)

      assert {:error, %{code: "invalid_input"}} =
               call(mode, :run, %{command: "pwd", timeout_ms: 0}, ctx)

      assert {:error, %Error{code: :not_found}} = Workspace.read(ctx.restricted, "/blocked")
      refute_receive {:signal, _}
    end

    test "nonzero process exit retains output through #{mode}", ctx do
      {:ok, _} = Workspace.start_session(ctx.ws, backend: {ProcessBackend, %{}})

      assert {:ok, %{status: :exited, exit_status: 7, output: "before\nafter\n"}} =
               call(
                 unquote(mode),
                 :run,
                 %{command: "printf 'before\n'; printf 'after\n' >&2; exit 7"},
                 ctx
               )

      refute_receive {:signal, _}
    end

    test "a final observation error retains completed execution through #{mode}", ctx do
      {:ok, session} = Workspace.shell(ctx.ws)
      parent = self()

      observer =
        Task.async(fn ->
          {:ok, :subscribed} = Jido.Shell.ShellSessionServer.subscribe(session, self())
          send(parent, :observer_ready)
          assert_receive {:jido_shell_session, ^session, {:command_started, _}}, 2_000
          # Hold the final file observation until the controller terminates.
          :ok = :sys.suspend(ctx.ws.lifetime)
          assert_receive {:jido_shell_session, ^session, :command_done}, 2_000
          :sys.terminate(ctx.ws.lifetime, :normal)
        end)

      assert_receive :observer_ready

      assert {:ok,
              %{
                status: :exited,
                exit_status: 0,
                output: output,
                after_files: %{error: %{code: "closed"}}
              }} =
               call(unquote(mode), :run, %{command: "seq 1 50; write /effect done"}, ctx)

      assert output =~ "wrote"
      assert :ok = Task.await(observer)
      refute_receive {:signal, _}
    end

    test "explicit cancellation retains partial output through #{mode}", ctx do
      {:ok, session} = Workspace.shell(ctx.ws)
      parent = self()

      observer =
        Task.async(fn ->
          {:ok, :subscribed} = Jido.Shell.ShellSessionServer.subscribe(session, self())
          send(parent, :observer_ready)
          assert_receive {:jido_shell_session, ^session, {:output, _}}, 2_000
          assert {:ok, :cancelled} = Jido.Shell.ShellSessionServer.cancel(session)
          Jido.Shell.ShellSessionServer.unsubscribe(session, self())
        end)

      assert_receive :observer_ready

      assert {:ok, %{status: :cancelled, exit_status: nil, output: output}} =
               call(unquote(mode), :run, %{command: "seq 100 10"}, ctx)

      assert output != ""
      assert {:ok, :unsubscribed} = Task.await(observer)

      assert {:ok, %{output: "ready\n"}} =
               call(unquote(mode), :run, %{command: "echo ready"}, ctx)

      refute_receive {:signal, _}
    end
  end

  defp call(:direct, operation, params, ctx) do
    resource = Map.get(ctx, :resource_id, "draft")
    store = ctx.access.store

    result =
      case operation do
        :info ->
          with {:ok, info} <- Workspace.info(ctx.ws),
               do: {:ok, Map.take(info, [:id, :policy, :session])}

        :list ->
          with {:ok, entries} <- Workspace.list(ctx.ws, params.path),
               do: {:ok, %{entries: Enum.map(entries, &Map.from_struct/1)}}

        :capture ->
          with {:ok, capture, revision} <- Workspace.capture(ctx.ws),
               do:
                 {:ok,
                  %{
                    capture_ref: ActionBoundary.put(store, resource, :capture, capture),
                    revision_ref: ActionBoundary.put(store, resource, :revision, revision)
                  }}

        :replace ->
          with {:ok, capture} <-
                 ActionBoundary.fetch(store, resource, :capture, params.capture_ref),
               {:ok, revision} <-
                 ActionBoundary.fetch(store, resource, :revision, params.revision_ref),
               {:ok, next} <- Workspace.replace(ctx.ws, capture, expected: revision),
               do: {:ok, %{revision_ref: ActionBoundary.put(store, resource, :revision, next)}}

        :file_view ->
          with {:ok, view} <- Workspace.file_view(ctx.ws),
               do: {:ok, %{file_view_ref: ActionBoundary.put(store, resource, :file_view, view)}}

        :run ->
          expected =
            if ref = Map.get(params, :file_view_ref),
              do: ActionBoundary.fetch(store, resource, :file_view, ref),
              else: {:ok, :current}

          with {:ok, view} <- expected,
               {:ok, %Execution{} = record} <-
                 Workspace.run(ctx.ws, params.command,
                   files: view,
                   timeout_ms: Map.get(params, :timeout_ms, 30_000),
                   output_limit: Map.get(params, :output_limit, 1_048_576)
                 ),
               do: {:ok, ActionBoundary.execution_data(record, store, resource, view)}

        :start_session ->
          with {:ok, session} <- Workspace.start_session(ctx.ws),
               do: {:ok, %{session_ref: ActionBoundary.put(store, resource, :session, session)}}

        :shell ->
          with {:ok, session} <- Workspace.shell(ctx.ws),
               do: {:ok, %{session_ref: ActionBoundary.put(store, resource, :session, session)}}

        :filesystem ->
          with {:ok, fs} <- Workspace.filesystem(ctx.ws),
               do: {:ok, %{filesystem_ref: ActionBoundary.put(store, resource, :filesystem, fs)}}

        :stop_session ->
          with :ok <- Workspace.stop_session(ctx.ws), do: {:ok, %{stopped: true}}
      end

    normalize(result)
  end

  defp call(:action, operation, params, ctx) do
    case Jido.Exec.run(
           action(operation),
           parameters(params, ctx),
           %{workspace_access: ctx.access},
           max_retries: 0
         ) do
      {:ok, %{result: data}} -> {:ok, data}
      {:error, %{details: %{domain_error: error}}} -> normalize({:error, error})
    end
  end

  defp call(:signal, operation, params, ctx) do
    params = parameters(params, ctx)
    prefix = "jido.workspace.v1.workspace.#{operation}"
    request = Jido.Signal.new!(prefix <> ".requested", params, source: "/workspace/contract-test")
    Jido.AgentServer.call(ctx.agent, request)
    %{request_id: request_id, resource_id: resource_id} = params
    causation = request.id

    assert_receive {:signal,
                    %Jido.Signal{
                      type: type,
                      data:
                        %{
                          request_id: ^request_id,
                          resource_id: ^resource_id,
                          causation_id: ^causation
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
        {:error, error}
    end
  end

  defp normalize({:error, %Error{} = e}),
    do:
      {:error,
       %{code: to_string(e.code), operation: to_string(e.operation), resource: e.resource}}

  defp normalize(result), do: result

  defp parameters(params, ctx),
    do:
      Map.merge(params, %{
        request_id: "request-#{System.unique_integer([:positive, :monotonic])}",
        resource_id: Map.get(ctx, :resource_id, "draft")
      })

  defp action(:info), do: Actions.Info
  defp action(:list), do: Actions.List
  defp action(:capture), do: Actions.Capture
  defp action(:replace), do: Actions.Replace
  defp action(:file_view), do: Actions.FileView
  defp action(:run), do: Actions.Run
  defp action(:start_session), do: Actions.StartSession
  defp action(:stop_session), do: Actions.StopSession
  defp action(:shell), do: Actions.Shell
  defp action(:filesystem), do: Actions.Filesystem
end
