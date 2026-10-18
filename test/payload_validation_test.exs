defmodule Jido.Workspace.PayloadValidationTest do
  use ExUnit.Case, async: true
  alias Jido.Workspace.Deploy.{Artifact, Recipe, Snapshot}
  alias Jido.Workspace.Error
  alias Jido.Workspace.Sandbox
  alias Jido.Workspace.Sandbox.Files

  @tag :tmp_dir
  test "snapshots refuse malformed entries and detect missing or changed files", %{tmp_dir: root} do
    assert {:error, :invalid_snapshot} = Snapshot.new(%{"file" => "bytes"})
    refute Snapshot.valid?(nil)
    {:ok, snapshot} = Snapshot.new(%{"file" => %{bytes: "original", mode: 0o644}})
    refute Snapshot.valid?(%{snapshot | entries: %{"file" => %{bytes: "bytes", mode: 0o777}}})
    assert {:error, :enoent} = Snapshot.from_directory(Path.join(root, "missing"))
    File.write!(Path.join(root, "file"), "changed")
    assert {:error, :content_mismatch} = Snapshot.verify(snapshot, root)
    assert {:error, {:source_changed, "file"}} = Snapshot.verify_tracked(snapshot, root)
    refute Artifact.valid?(nil)
    assert {:error, :invalid_artifact} = Artifact.new(:unknown, "1", snapshot)
  end

  test "recipes validate argument types and command options" do
    assert Recipe.valid?(%Recipe{prepare: [{"/bin/true", [], env: []}]})
    refute Recipe.valid?(%Recipe{prepare: [{"/bin/true", [], [:invalid]}]})
    refute Recipe.valid?(%Recipe{prepare: [:invalid]})
    refute Recipe.valid?(%Recipe{verify: {"/bin/true", [123]}})
    refute Recipe.valid?(:unknown)
  end

  test "public errors retain the operation and use bounded diagnostics" do
    for {reason, code} <- [
          {:already_exists, :already_exists},
          {:directory_not_empty, :directory_not_empty},
          {:not_directory, :not_directory},
          {:invalid_file_view, :invalid_input},
          {:unexpected, :operation_failed}
        ] do
      assert %Error{operation: :write, resource: "resource", code: ^code} =
               Error.from_reason(:write, "resource", reason)
    end

    error = Error.from_reason(:read, nil, String.duplicate("secret", 1000))
    assert byte_size(error.details.cause) < 250
  end

  test "file helpers refuse invalid modes and links and retain directory entries" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    root = sandbox.root
    assert {:error, :invalid_path} = Files.path(root, nil)
    assert {:error, :invalid_mode} = Files.write(root, "file", "bytes", 0o777)
    assert :ok = Files.mkdir(root, "dir", false)
    assert :ok = Files.write(root, "dir/run", "bytes", 0o755)
    File.ln_s!("run", Path.join(root, "dir/link"))
    assert {:ok, "run"} = Files.read_link(root, "dir/link")
    assert {:error, :invalid_path} = Files.replace_link(root, "dir/link", "run", "bad/nonce")
    assert {:error, :invalid_path} = Files.replace_link(root, "../link", "run", "nonce")
    assert {:ok, entries} = Files.capture(root, ".", true)
    assert entries["dir"] == %{type: :directory}
    assert entries["dir/link"] == %{type: :symlink, target: "run"}
    assert {:error, :content_mismatch} = Files.verify(root, "missing", %{}, false)
  end
end
