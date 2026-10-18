defmodule Jido.Workspace.Integration.Scenario03WorkspaceSnapshotRestoreTest do
  use ExUnit.Case, async: false
  alias Jido.Workspace
  @moduletag :integration

  test "memory capture restores a complete tree through checked replacement" do
    {:ok, ws} = Workspace.open()

    try do
      :ok = Workspace.write(ws, "/original", "saved")
      :ok = Workspace.mkdir(ws, "/empty")
      {:ok, capture, _} = Workspace.capture(ws)
      :ok = Workspace.delete(ws, "/original")
      :ok = Workspace.write(ws, "/new", "new")
      {:ok, _, revision} = Workspace.capture(ws)
      {:ok, _} = Workspace.replace(ws, capture, expected: revision)
      assert {:ok, "saved"} = Workspace.read(ws, "/original")
      assert {:error, %Jido.Workspace.Error{code: :not_found}} = Workspace.read(ws, "/new")
      assert {:ok, []} = Workspace.list(ws, "/empty")
    after
      Workspace.close(ws)
    end
  end

  @tag :tmp_dir
  test "local storage refuses an atomic capture instead of walking live files", %{tmp_dir: dir} do
    {:ok, ws} = Workspace.open(adapter: Jido.VFS.Adapter.Local, adapter_opts: [prefix: dir])

    try do
      assert {:error, %Jido.Workspace.Error{code: :unsupported_capability}} =
               Workspace.capture(ws)
    after
      Workspace.close(ws)
    end
  end
end
