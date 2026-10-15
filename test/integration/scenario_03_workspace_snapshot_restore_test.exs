defmodule Jido.Workspace.Integration.Scenario03WorkspaceSnapshotRestoreTest do
  use ExUnit.Case, async: false
  alias Jido.Workspace
  @moduletag :integration

  test "memory capture restores a complete tree through the legacy convenience API" do
    ws = Workspace.new()

    try do
      {:ok, ws} = Workspace.write(ws, "/original", "saved")
      {:ok, ws} = Workspace.mkdir(ws, "/empty")
      {:ok, capture, ws} = Workspace.snapshot(ws)
      {:ok, ws} = Workspace.delete(ws, "/original")
      {:ok, ws} = Workspace.write(ws, "/new", "new")
      {:ok, ws} = Workspace.restore(ws, capture)
      assert {:ok, "saved"} = Workspace.read(ws, "/original")
      assert {:error, :file_not_found} = Workspace.read(ws, "/new")
      assert {:ok, []} = Workspace.list(ws, "/empty")
    after
      Workspace.close(ws)
    end
  end

  @tag :tmp_dir
  test "local storage refuses an atomic capture instead of walking live files", %{tmp_dir: dir} do
    ws = Workspace.new(adapter: Jido.VFS.Adapter.Local, adapter_opts: [prefix: dir])

    try do
      assert {:error, %Jido.VFS.Errors.UnsupportedOperation{}} = Workspace.snapshot(ws)
    after
      Workspace.close(ws)
    end
  end
end
