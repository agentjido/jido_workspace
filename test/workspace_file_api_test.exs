defmodule Jido.Workspace.FileApiTest do
  use ExUnit.Case, async: false
  alias Jido.Workspace
  alias Jido.Workspace.Error

  test "file mutations keep one handle and return the new results" do
    {:ok, ws} = Workspace.open()
    on_exit(fn -> Workspace.close(ws) end)

    assert :ok = Workspace.write(ws, "/file", ["new", [32, "bytes"]])
    assert {:ok, "new bytes"} = Workspace.read(ws, "/file")
    assert {:ok, [%Jido.Workspace.Entry{path: "/file"}]} = Workspace.list(ws)

    assert {:error, %Error{code: :not_found, operation: :read, resource: id}} =
             Workspace.read(ws, "/absent")

    assert id == ws.id
    assert :ok = Workspace.close(ws)
    assert :ok = Workspace.close(ws)
  end

  test "invalid paths and bytes fail before changing files" do
    {:ok, ws} = Workspace.open()
    on_exit(fn -> Workspace.close(ws) end)
    assert :ok = Workspace.write(ws, "/keep", "safe")

    for path <- ["relative", "/../keep", "/bad\0path", <<255>>, nil] do
      assert {:error, %Error{code: :invalid_input, operation: :write}} =
               Workspace.write(ws, path, "bad")

      assert {:error, %Error{code: :invalid_input, operation: :read}} = Workspace.read(ws, path)
      assert {:error, %Error{code: :invalid_input, operation: :mkdir}} = Workspace.mkdir(ws, path)

      assert {:error, %Error{code: :invalid_input, operation: :delete}} =
               Workspace.delete(ws, path)
    end

    assert {:error, %Error{code: :invalid_input}} = Workspace.write(ws, "/keep", %{bad: "bytes"})
    assert {:ok, "safe"} = Workspace.read(ws, "/keep")
    assert {:error, %Error{code: :invalid_input, operation: :open}} = Workspace.open(:invalid)

    assert {:error, %Error{code: :invalid_input, operation: :open}} =
             Workspace.open(owner: :invalid)

    assert {:error, %Error{code: :invalid_input, operation: :open}} =
             Workspace.open(policy: :unknown)
  end

  test "closed handles cannot change a new workspace with the same ID" do
    {:ok, old} = Workspace.open(id: "file-api-reused")
    assert :ok = Workspace.close(old)
    {:ok, fresh} = Workspace.open(id: "file-api-reused")
    on_exit(fn -> Workspace.close(fresh) end)
    assert :ok = Workspace.write(fresh, "/keep", "safe")
    assert {:error, %Error{code: :closed}} = Workspace.write(old, "/keep", "bad")
    assert :ok = Workspace.close(old)
    assert {:ok, "safe"} = Workspace.read(fresh, "/keep")
  end

  test "owner exit closes a workspace" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, ws} = Workspace.open()
        send(parent, {:workspace, ws})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:workspace, ws}
    monitor = Process.monitor(ws.lifetime)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 2_000
    assert {:error, %Error{code: :closed, operation: :read}} = Workspace.read(ws, "/file")
    assert :ok = Workspace.close(ws)
  end

  test "a busy request does not complete another caller's command" do
    {:ok, ws} = Workspace.open()
    on_exit(fn -> Workspace.close(ws) end)
    {:ok, session} = Workspace.shell(ws)
    {:ok, :subscribed} = Jido.Shell.ShellSessionServer.subscribe(session, self())
    running = Task.async(fn -> Workspace.run(ws, "seq 20 5") end)
    assert_receive {:jido_shell_session, ^session, {:command_started, "seq 20 5"}}
    assert {:error, %Error{code: :busy, operation: :run}} = Workspace.run(ws, "echo other")
    assert {:ok, %{status: :exited, exit_status: 0, output: output}} = Task.await(running)
    assert output =~ "20"
    {:ok, :unsubscribed} = Jido.Shell.ShellSessionServer.unsubscribe(session, self())
  end

  test "replacement rejects revisions from another resource generation" do
    {:ok, old} = Workspace.open(id: "capture-reused")
    :ok = Workspace.write(old, "/input", "old")
    {:ok, saved, revision} = Workspace.capture(old)
    :ok = Workspace.close(old)
    {:ok, fresh} = Workspace.open(id: "capture-reused")
    on_exit(fn -> Workspace.close(fresh) end)
    :ok = Workspace.write(fresh, "/input", "fresh")

    assert {:error, %Error{code: :stale_revision}} =
             Workspace.replace(fresh, saved, expected: revision)

    assert {:error, %Error{code: :closed}} = Workspace.capture(old)
    assert {:error, %Error{code: :closed}} = Workspace.replace(old, saved, expected: revision)
    assert {:ok, "fresh"} = Workspace.read(fresh, "/input")
  end

  test "invalid command and replacement options do not stop the controller" do
    {:ok, ws} = Workspace.open()
    on_exit(fn -> Workspace.close(ws) end)
    {:ok, capture, revision} = Workspace.capture(ws)

    for opts <- [[], :invalid, [expected: revision, extra: true]] do
      assert {:error, %Error{code: :invalid_input}} = Workspace.replace(ws, capture, opts)
    end

    for opts <- [
          :invalid,
          [timeout: 10],
          [timeout_ms: -1],
          [output_limit: -1],
          [execution_context: []]
        ] do
      assert {:error, %Error{code: :invalid_input}} = Workspace.run(ws, "pwd", opts)
    end

    assert {:error, %Error{code: :invalid_input}} = Workspace.start_session(ws, :invalid)
    assert {:ok, %{session: :stopped}} = Workspace.info(ws)
  end
end
