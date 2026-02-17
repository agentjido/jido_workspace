defmodule Jido.SandboxTest do
  use ExUnit.Case

  describe "new/0" do
    test "creates a new sandbox" do
      sandbox = Jido.Sandbox.new()
      assert is_struct(sandbox, Jido.Sandbox.Sandbox)
    end

    test "sandbox has empty VFS" do
      sandbox = Jido.Sandbox.new()
      assert is_struct(sandbox.vfs, Jido.Sandbox.VFS.InMemory)
    end
  end

  describe "write/3 and read/2" do
    test "write and read roundtrip" do
      sandbox = Jido.Sandbox.new()
      {:ok, sandbox} = Jido.Sandbox.write(sandbox, "/hello.txt", "Hello, World!")
      {:ok, content} = Jido.Sandbox.read(sandbox, "/hello.txt")
      assert content == "Hello, World!"
    end

    test "write accepts iodata" do
      sandbox = Jido.Sandbox.new()
      {:ok, sandbox} = Jido.Sandbox.write(sandbox, "/test.txt", ["a", "b", "c"])
      {:ok, content} = Jido.Sandbox.read(sandbox, "/test.txt")
      assert content == "abc"
    end

    test "read non-existent file returns error" do
      sandbox = Jido.Sandbox.new()
      assert {:error, :file_not_found} = Jido.Sandbox.read(sandbox, "/missing.txt")
    end

    test "write to non-existent directory returns error" do
      sandbox = Jido.Sandbox.new()
      assert {:error, :parent_directory_not_found} = Jido.Sandbox.write(sandbox, "/foo/bar.txt", "x")
    end
  end

  describe "mkdir/2" do
    test "creates a directory" do
      sandbox = Jido.Sandbox.new()
      {:ok, sandbox} = Jido.Sandbox.mkdir(sandbox, "/mydir")
      {:ok, entries} = Jido.Sandbox.list(sandbox, "/")
      assert "mydir/" in entries
    end

    test "allows writing to created directory" do
      sandbox = Jido.Sandbox.new()
      {:ok, sandbox} = Jido.Sandbox.mkdir(sandbox, "/mydir")
      {:ok, sandbox} = Jido.Sandbox.write(sandbox, "/mydir/file.txt", "content")
      {:ok, content} = Jido.Sandbox.read(sandbox, "/mydir/file.txt")
      assert content == "content"
    end
  end

  describe "list/2" do
    test "lists files in root" do
      sandbox = Jido.Sandbox.new()
      {:ok, sandbox} = Jido.Sandbox.write(sandbox, "/a.txt", "a")
      {:ok, sandbox} = Jido.Sandbox.write(sandbox, "/b.txt", "b")
      {:ok, entries} = Jido.Sandbox.list(sandbox, "/")
      assert entries == ["a.txt", "b.txt"]
    end

    test "lists files and directories" do
      sandbox = Jido.Sandbox.new()
      {:ok, sandbox} = Jido.Sandbox.write(sandbox, "/file.txt", "x")
      {:ok, sandbox} = Jido.Sandbox.mkdir(sandbox, "/dir")
      {:ok, entries} = Jido.Sandbox.list(sandbox, "/")
      assert entries == ["dir/", "file.txt"]
    end
  end

  describe "delete/2" do
    test "deletes a file" do
      sandbox = Jido.Sandbox.new()
      {:ok, sandbox} = Jido.Sandbox.write(sandbox, "/test.txt", "x")
      {:ok, sandbox} = Jido.Sandbox.delete(sandbox, "/test.txt")
      assert {:error, :file_not_found} = Jido.Sandbox.read(sandbox, "/test.txt")
    end

    test "deletes empty directory" do
      sandbox = Jido.Sandbox.new()
      {:ok, sandbox} = Jido.Sandbox.mkdir(sandbox, "/empty")
      {:ok, sandbox} = Jido.Sandbox.delete(sandbox, "/empty")
      {:ok, entries} = Jido.Sandbox.list(sandbox, "/")
      refute "empty/" in entries
    end
  end

  describe "snapshot/1 and restore/2" do
    test "creates a snapshot and returns an ID" do
      sandbox = Jido.Sandbox.new()
      {:ok, snapshot_id, new_sandbox} = Jido.Sandbox.snapshot(sandbox)

      assert is_binary(snapshot_id)
      assert String.starts_with?(snapshot_id, "snap-")
      assert new_sandbox.next_snapshot_id == 1
    end

    test "increments snapshot ID" do
      sandbox = Jido.Sandbox.new()
      {:ok, "snap-0", sandbox} = Jido.Sandbox.snapshot(sandbox)
      {:ok, "snap-1", sandbox} = Jido.Sandbox.snapshot(sandbox)
      {:ok, "snap-2", _sandbox} = Jido.Sandbox.snapshot(sandbox)
    end

    test "restore brings back previous state" do
      sandbox = Jido.Sandbox.new()
      {:ok, sandbox} = Jido.Sandbox.write(sandbox, "/original.txt", "original")
      {:ok, snapshot_id, sandbox} = Jido.Sandbox.snapshot(sandbox)

      # Modify the state
      {:ok, sandbox} = Jido.Sandbox.write(sandbox, "/new.txt", "new")
      {:ok, sandbox} = Jido.Sandbox.delete(sandbox, "/original.txt")

      # Verify new state
      assert {:error, :file_not_found} = Jido.Sandbox.read(sandbox, "/original.txt")
      {:ok, "new"} = Jido.Sandbox.read(sandbox, "/new.txt")

      # Restore
      {:ok, sandbox} = Jido.Sandbox.restore(sandbox, snapshot_id)

      # Verify restored state
      {:ok, "original"} = Jido.Sandbox.read(sandbox, "/original.txt")
      assert {:error, :file_not_found} = Jido.Sandbox.read(sandbox, "/new.txt")
    end

    test "returns error for unknown snapshot" do
      sandbox = Jido.Sandbox.new()
      assert {:error, :unknown_snapshot} = Jido.Sandbox.restore(sandbox, "snap-999")
    end
  end

  describe "eval_lua/2" do
    test "evaluates Lua code and returns result" do
      sandbox = Jido.Sandbox.new()
      assert {:ok, 1, _sandbox} = Jido.Sandbox.eval_lua(sandbox, "return 1")
    end
  end
end
