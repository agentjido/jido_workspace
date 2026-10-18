defmodule Jido.Workspace.OwnedWorkspaceTest do
  use ExUnit.Case, async: false
  alias Jido.Workspace

  test "one owned environment shares shell edits and checked captures" do
    {:ok, ws} = Workspace.open()

    try do
      {:ok, fs} = Workspace.filesystem(ws)
      {:ok, shell} = Workspace.shell(ws)
      assert {:ok, ^shell} = Workspace.shell(ws)
      {:ok, before, token} = Workspace.capture(ws)
      assert :ok = Jido.Shell.Agent.write_file(shell, "/source", "new")

      assert {:error, %Jido.Workspace.Error{code: :stale_revision}} =
               Workspace.replace(ws, before, expected: token)

      assert {:ok, "new"} = Jido.VFS.read(fs, "source")
      {:ok, current, token} = Workspace.capture(ws)
      assert {:ok, _} = Workspace.replace(ws, before, expected: token)
      assert :ok = Workspace.stop_session(ws)
      assert {:ok, :missing} = Jido.VFS.file_exists(fs, "source")
      :ok = Workspace.close(ws)
      assert {:ok, "new"} = Jido.VFS.read(current, "source")
      assert :ok = Workspace.close(ws)
      assert {:error, %Jido.Workspace.Error{code: :closed}} = Workspace.filesystem(ws)
    after
      Workspace.close(ws)
    end
  end

  test "owner exit stops commands and storage without deleting captures" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, ws} = Workspace.open()
        {:ok, fs} = Workspace.filesystem(ws)
        {:ok, shell} = Workspace.shell(ws)
        :ok = Jido.VFS.write(fs, "source", "saved")
        {:ok, saved, _} = Workspace.capture(ws)
        send(parent, {:workspace, ws, fs, shell, saved})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:workspace, ws, {_adapter, config}, shell, saved}
    storage = GenServer.whereis(Jido.VFS.Registry.via(Jido.VFS.Adapter.InMemory, config.name))
    {:ok, session} = Jido.Shell.ShellSession.lookup(shell)
    refs = Enum.map([ws.lifetime, storage, session], &Process.monitor/1)

    {:ok, :accepted} =
      Jido.Shell.ShellSessionServer.run_command(shell, "sleep 30; write /late bad")

    {:ok, state} = Jido.Shell.ShellSessionServer.get_state(shell)
    task = state.current_command.task
    send(owner, :stop)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 2_000)
    refute Process.alive?(task)
    assert {:ok, "saved"} = Jido.VFS.read(saved, "source")
    assert Jido.Shell.VFS.list_mounts(ws.id) == []
  end

  test "failed session startup releases storage and routes" do
    name = make_ref()

    assert {:error, _} =
             Workspace.open(
               id: "failed-owned-start",
               adapter_opts: [name: name],
               start_session: true,
               session_opts: [backend: {NotABackend, %{}}]
             )

    assert GenServer.whereis(Jido.VFS.Registry.via(Jido.VFS.Adapter.InMemory, name)) == nil
    assert Jido.Shell.VFS.list_mounts("failed-owned-start") == []
  end

  test "storage failure closes the environment instead of restarting it empty" do
    {:ok, ws} = Workspace.open()
    {:ok, {_adapter, config}} = Workspace.filesystem(ws)
    {:ok, shell} = Workspace.shell(ws)
    {:ok, session} = Jido.Shell.ShellSession.lookup(shell)
    ref = Process.monitor(ws.lifetime)
    session_ref = Process.monitor(session)
    storage = GenServer.whereis(Jido.VFS.Registry.via(Jido.VFS.Adapter.InMemory, config.name))
    Process.exit(storage, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    assert_receive {:DOWN, ^session_ref, :process, _, _}, 2_000
    assert {:error, %Jido.Workspace.Error{code: :closed}} = Workspace.filesystem(ws)
  end

  test "captures refuse multiple mounts" do
    {:ok, ws} = Workspace.open()

    try do
      :ok = Jido.Shell.VFS.mount(ws.id, "/scratch", Jido.VFS.Adapter.InMemory, name: make_ref())

      assert {:error, %Jido.Workspace.Error{code: :unsupported_capability}} =
               Workspace.capture(ws)
    after
      Workspace.close(ws)
    end
  end

  test "closed handles cannot access a new workspace with the same ID" do
    {:ok, old} = Workspace.open(id: "reused-workspace")
    :ok = Workspace.close(old)
    {:ok, fresh} = Workspace.open(id: "reused-workspace")

    try do
      :ok = Workspace.write(fresh, "/keep", "safe")
      assert {:error, %Jido.Workspace.Error{code: :closed}} = Workspace.write(old, "/keep", "bad")
      assert {:error, %Jido.Workspace.Error{code: :closed}} = Workspace.read(old, "/keep")
      assert {:error, %Jido.Workspace.Error{code: :closed}} = Workspace.list(old)
      assert {:error, %Jido.Workspace.Error{code: :closed}} = Workspace.delete(old, "/keep")
      assert {:error, %Jido.Workspace.Error{code: :closed}} = Workspace.mkdir(old, "/bad")
      assert {:ok, "safe"} = Workspace.read(fresh, "/keep")
    after
      Workspace.close(fresh)
    end
  end

  test "reused session names do not transfer ownership" do
    {:ok, a} = Workspace.open()
    {:ok, b} = Workspace.open()
    id = "reused-owned-session"

    try do
      {:ok, _} = Workspace.start_session(a, session_id: id)
      :ok = Jido.Shell.ShellSession.stop(id)
      {:ok, _} = Workspace.start_session(b, session_id: id)
      {:ok, b_pid} = Jido.Shell.ShellSession.lookup(id)
      assert {:ok, _} = Workspace.run(a, "write /only-a yes")
      assert {:ok, "yes"} = Workspace.read(a, "/only-a")
      assert {:error, _} = Workspace.read(b, "/only-a")
      :ok = Workspace.close(a)
      assert Process.alive?(b_pid)
    after
      Workspace.close(a)
      Workspace.close(b)
    end
  end
end
