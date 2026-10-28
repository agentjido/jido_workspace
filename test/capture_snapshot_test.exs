defmodule Jido.Workspace.Deploy.CaptureSnapshotTest do
  use ExUnit.Case, async: true
  alias Jido.VFS
  alias Jido.VFS.Adapter.InMemory
  alias Jido.VFS.Capture
  alias Jido.Workspace.Deploy.Snapshot

  test "conversion retains fixed bytes and modes after storage changes and stops" do
    fs = InMemory.configure(name: make_ref())
    {:ok, storage} = InMemory.start_link(fs)
    :ok = VFS.write(fs, "bin/run", <<0, 255>>, mode: :executable)
    :ok = VFS.write(fs, "notes.txt", "hello\n")
    :ok = VFS.create_directory(fs, "empty/")
    {:ok, capture, _revision} = VFS.capture(fs)
    :ok = VFS.write(fs, "bin/run", "changed", mode: :regular)
    GenServer.stop(storage)

    assert {:ok, snapshot} = Snapshot.from_capture(capture, id: "accepted-source")

    assert snapshot.entries == %{
             "bin/run" => %{bytes: <<0, 255>>, mode: 0o755},
             "notes.txt" => %{bytes: "hello\n", mode: 0o644}
           }

    assert {:ok, expected} = Snapshot.new(snapshot.entries)
    assert snapshot.digest == expected.digest
    assert snapshot.id == "accepted-source"
    assert expected.id == expected.digest
    assert Snapshot.valid?(snapshot)
    assert {:ok, %{digest: digest, id: digest}} = Snapshot.from_capture(capture)
    assert digest == expected.digest
  end

  test "conversion ignores unrelated metadata and empty directories" do
    file = %{type: :file, content: "", metadata: %{mtime: 123, visibility: :private}}
    {:ok, a} = Snapshot.from_capture(%Capture{entries: %{"file" => file}})

    {:ok, b} =
      Snapshot.from_capture(%Capture{
        entries: %{
          "file" => %{file | metadata: %{mtime: 456, mode: :regular}},
          "empty" => %{type: :directory, metadata: %{}}
        }
      })

    assert a == b
    assert {:ok, empty} = Snapshot.from_capture(%Capture{entries: %{}})
    assert empty.entries == %{}
  end

  test "invalid capture entries cannot be silently dropped or change deployment paths" do
    file = %{type: :file, content: "bytes", metadata: %{mode: :regular}}
    directory = %{type: :directory, metadata: %{}}

    for entries <- [
          %{"../escape" => file},
          %{"/absolute" => file},
          %{"a//b" => file},
          %{"a\\b" => file},
          %{"bad\0path" => file},
          %{<<255>> => file},
          %{123 => file},
          %{"dir/file" => file},
          %{"a" => file, "a/b" => file},
          %{"../empty" => directory},
          %{"file" => %{file | content: :invalid}},
          %{"file" => %{file | metadata: %{mode: 0o755}}},
          %{"file" => %{file | metadata: :invalid}},
          %{"dir" => %{directory | metadata: :invalid}},
          %{"link" => %{type: :symlink, content: "file", metadata: %{}}},
          %{"device" => %{type: :device, metadata: %{}}}
        ] do
      assert {:error, :invalid_capture} = Snapshot.from_capture(%Capture{entries: entries})
    end

    assert {:error, :invalid_capture} = Snapshot.from_capture(%Capture{entries: nil})
    assert {:error, :invalid_capture} = Snapshot.from_capture(:live_filesystem)
  end
end
