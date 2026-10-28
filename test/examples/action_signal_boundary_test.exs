defmodule Jido.Workspace.ActionSignalBoundaryTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag capture_log: true

  alias Jido.Workspace
  alias Jido.Workspace.{Deploy, Sandbox}
  alias Jido.Workspace.Deploy.{Artifact, Snapshot}
  alias Jido.Workspace.TestSupport.{ActionBoundary, Actions, BoundaryAgent}

  setup do
    start_supervised!({Jido, name: __MODULE__.Runtime})
    store = start_supervised!({Agent, fn -> %{} end})
    {:ok, ws} = Workspace.open()
    {:ok, restricted} = Workspace.open(policy: :read_only)
    {:ok, sandbox} = Sandbox.open()

    on_exit(fn ->
      Workspace.close(ws)
      Workspace.close(restricted)
      Sandbox.destroy(sandbox)
    end)

    {:ok, target} = Deploy.source_target(sandbox, "site")
    {:ok, deployment} = Deploy.connect(target)

    access = %{
      store: store,
      reply_to: self(),
      resources: %{
        "draft" => {:workspace, ws},
        "readonly" => {:workspace, restricted},
        "execution" => {:sandbox, sandbox},
        "site" => {:deployment, deployment}
      }
    }

    agent =
      start_supervised!(
        {Jido.AgentServer,
         jido: __MODULE__.Runtime,
         agent: BoundaryAgent,
         initial_state: %{workspace_access: access}}
      )

    %{
      access: access,
      ws: ws,
      restricted: restricted,
      sandbox: sandbox,
      deployment: deployment,
      agent: agent
    }
  end

  test "Actions and Agent Signals share real files, captures, and checked replacement", ctx do
    params = %{request_id: "direct-write", resource_id: "draft", path: "/input", content: "first"}

    assert {:ok, %{request_id: "direct-write", result: %{path: "/input"}}} =
             Jido.Exec.run(Actions.Write, params, %{workspace_access: ctx.access}, max_retries: 0)

    assert {:ok, "first"} = Workspace.read(ctx.ws, "/input")

    assert %{result: %{content: "first"}} =
             request(ctx.agent, "workspace.read", %{path: "/input"})

    {:ok, view} = Workspace.file_view(ctx.ws)
    view_ref = ActionBoundary.put(ctx.access.store, "draft", :file_view, view)

    assert %{result: %{output: "first", checked_files: true}} =
             request(ctx.agent, "workspace.run", %{command: "cat /input", file_view_ref: view_ref})

    saved = request(ctx.agent, "workspace.capture", %{}).result
    request(ctx.agent, "workspace.write", %{path: "/input", content: "second"})

    assert %{error: %{code: "stale_file_view"}} =
             request(
               ctx.agent,
               "workspace.run",
               %{command: "write /marker bad", file_view_ref: view_ref},
               "draft",
               "failed"
             )

    assert {:error, %Jido.Workspace.Error{code: :not_found}} = Workspace.read(ctx.ws, "/marker")

    assert %{error: %{code: "stale_revision"}} =
             request(ctx.agent, "workspace.replace", saved, "draft", "failed")

    assert {:ok, "second"} = Workspace.read(ctx.ws, "/input")
    current = request(ctx.agent, "workspace.capture", %{}).result

    assert %{result: %{revision_ref: _}} =
             request(ctx.agent, "workspace.replace", %{saved | revision_ref: current.revision_ref})

    assert {:ok, "first"} = Workspace.read(ctx.ws, "/input")
    {:ok, capture} = ActionBoundary.fetch(ctx.access.store, "draft", :capture, saved.capture_ref)
    :ok = Workspace.close(ctx.ws)
    assert {:ok, "first"} = Jido.VFS.read(capture, "input")
    refute_receive {:signal, _}
  end

  test "policy, resource access, and Action schemas refuse changes", ctx do
    assert %{error: %{code: "policy_denied", operation: "write"}} =
             request(
               ctx.agent,
               "workspace.write",
               %{path: "/blocked", content: "bad"},
               "readonly",
               "failed"
             )

    assert {:error, %Jido.Workspace.Error{code: :not_found}} =
             Workspace.read(ctx.restricted, "/blocked")

    assert %{error: %{code: "resource_not_found"}} =
             request(
               ctx.agent,
               "workspace.write",
               %{path: "/blocked", content: "bad"},
               "unknown",
               "failed"
             )

    assert {:error, _} =
             Jido.Exec.run(
               Actions.Write,
               %{request_id: "invalid", resource_id: "draft", path: "/blocked", content: 42},
               %{workspace_access: ctx.access},
               max_retries: 0
             )

    assert {:error, %Jido.Workspace.Error{code: :not_found}} = Workspace.read(ctx.ws, "/blocked")

    saved = request(ctx.agent, "workspace.capture", %{}).result

    assert %{error: %{code: "resource_not_found"}} =
             request(ctx.agent, "workspace.replace", saved, "readonly", "failed")

    refute_receive {:signal, _}
  end

  test "Agent Signals run a local command and deploy the captured workspace bytes", ctx do
    request(ctx.agent, "workspace.write", %{path: "/index.txt", content: "accepted bytes"})
    {:ok, bytes} = Workspace.read(ctx.ws, "/index.txt")
    :ok = Sandbox.write(ctx.sandbox, "input.txt", bytes)

    assert %{result: %{output: "accepted bytes", exit_status: 0}} =
             request(
               ctx.agent,
               "sandbox.exec",
               %{executable: "/bin/cat", args: ["input.txt"]},
               "execution"
             )

    assert %{result: %{exit_status: 7}} =
             request(
               ctx.agent,
               "sandbox.exec",
               %{executable: "/bin/sh", args: ["-c", "exit 7"]},
               "execution"
             )

    {:ok, snapshot} = Snapshot.new(%{"index.txt" => %{bytes: bytes, mode: 0o644}}, id: "source-1")
    {:ok, artifact} = Artifact.new(:source, "1", snapshot)
    artifact_ref = ActionBoundary.put(ctx.access.store, "site", :artifact, artifact)

    prepared = request(ctx.agent, "deploy.prepare", %{artifact_ref: artifact_ref}, "site").result
    assert {:ok, %{identity: %{current: nil}}} = Deploy.inspect(ctx.deployment)
    refute File.exists?(Path.join(ctx.sandbox.root, "site/current"))

    applied = request(ctx.agent, "deploy.apply", prepared, "site").result
    assert %{result: ^applied} = request(ctx.agent, "deploy.apply", prepared, "site")

    assert %{
             result: %{
               status: "succeeded",
               source_id: "source-1",
               digest: digest,
               step_count: steps,
               state_policy: "files_only"
             }
           } =
             request(ctx.agent, "deploy.await", applied, "site")

    assert digest == snapshot.digest
    assert steps > 0
    assert File.read!(Path.join(ctx.sandbox.root, "site/current/index.txt")) == bytes

    assert :ok = Sandbox.destroy(ctx.sandbox)
    refute File.exists?(ctx.sandbox.root)
    refute Process.alive?(ctx.deployment)
  end

  defp request(agent, operation, data, resource_id \\ "draft", outcome \\ "succeeded") do
    request_id = "request-#{System.unique_integer([:positive, :monotonic])}"
    prefix = "jido.workspace.v1." <> operation

    signal =
      Jido.Signal.new!(
        prefix <> ".requested",
        Map.merge(data, %{request_id: request_id, resource_id: resource_id}),
        source: "/workspace/integration-test"
      )

    # An Agent acknowledgement does not prove that the requested operation succeeded.
    Jido.AgentServer.call(agent, signal, 15_000)

    expected_type = prefix <> "." <> outcome
    causation_id = signal.id

    assert_receive {:signal,
                    %Jido.Signal{
                      type: ^expected_type,
                      data:
                        %{
                          request_id: ^request_id,
                          resource_id: ^resource_id,
                          causation_id: ^causation_id
                        } = reply
                    }},
                   15_000

    assert {:ok, _} = Jason.encode(reply)
    reply
  end
end
