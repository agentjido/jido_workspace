defmodule Jido.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Jido.Workspace

  @moduletag :contract

  setup do
    {:ok, workspace} = Workspace.open()
    Process.put(:workspace_under_test, workspace)

    on_exit(fn ->
      case Process.get(:workspace_under_test) do
        %Jido.Workspace.Workspace{} = current ->
          _ = Workspace.close(current)
          :ok

        _ ->
          :ok
      end
    end)

    {:ok, workspace: workspace}
  end

  describe "artifact operations" do
    test "writes, reads, lists, and deletes files", %{workspace: workspace} do
      :ok = Workspace.write(workspace, "/hello.txt", "Hello, World!")
      Process.put(:workspace_under_test, workspace)

      assert {:ok, "Hello, World!"} = Workspace.read(workspace, "/hello.txt")

      assert {:ok, [%Jido.Workspace.Entry{path: "/hello.txt"}]} = Workspace.list(workspace, "/")

      :ok = Workspace.delete(workspace, "/hello.txt")
      Process.put(:workspace_under_test, workspace)

      assert {:error, %Jido.Workspace.Error{code: :not_found}} =
               Workspace.read(workspace, "/hello.txt")
    end

    test "creates and uses directories", %{workspace: workspace} do
      :ok = Workspace.mkdir(workspace, "/artifacts")
      :ok = Workspace.write(workspace, "/artifacts/note.md", "# Note")
      Process.put(:workspace_under_test, workspace)

      assert {:ok, [%Jido.Workspace.Entry{path: "/artifacts/note.md"}]} =
               Workspace.list(workspace, "/artifacts")

      assert {:ok, "# Note"} = Workspace.read(workspace, "/artifacts/note.md")
    end
  end

  describe "capture and checked replacement" do
    test "restores workspace tree to prior state", %{workspace: workspace} do
      :ok = Workspace.write(workspace, "/original.txt", "original")
      :ok = Workspace.mkdir(workspace, "/nested")
      :ok = Workspace.write(workspace, "/nested/a.txt", "a")

      {:ok, snapshot_id, _} = Workspace.capture(workspace)

      :ok = Workspace.delete(workspace, "/original.txt")
      :ok = Workspace.write(workspace, "/nested/new.txt", "new")
      Process.put(:workspace_under_test, workspace)

      assert {:error, %Jido.Workspace.Error{code: :not_found}} =
               Workspace.read(workspace, "/original.txt")

      assert {:ok, "new"} = Workspace.read(workspace, "/nested/new.txt")

      {:ok, _, revision} = Workspace.capture(workspace)
      {:ok, _} = Workspace.replace(workspace, snapshot_id, expected: revision)
      Process.put(:workspace_under_test, workspace)

      assert {:ok, "original"} = Workspace.read(workspace, "/original.txt")
      assert {:ok, "a"} = Workspace.read(workspace, "/nested/a.txt")

      assert {:error, %Jido.Workspace.Error{code: :not_found}} =
               Workspace.read(workspace, "/nested/new.txt")
    end

    test "rejects an invalid capture", %{workspace: workspace} do
      assert {:error, %Jido.Workspace.Error{code: :invalid_input}} =
               Workspace.replace(workspace, "snap-404", expected: :invalid)
    end
  end

  describe "shell session integration" do
    test "runs commands in workspace session", %{workspace: workspace} do
      assert {:ok, %{output: "/\n"}} = Workspace.run(workspace, "pwd")
      Process.put(:workspace_under_test, workspace)

      assert {:ok, %{session: :running}} = Workspace.info(workspace)

      assert {:ok, %{output: output}} = Workspace.run(workspace, "write /from_shell.txt hi")
      assert output =~ "wrote"
      Process.put(:workspace_under_test, workspace)

      assert {:ok, "hi"} = Workspace.read(workspace, "/from_shell.txt")
    end
  end
end
