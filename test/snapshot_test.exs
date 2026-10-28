defmodule Jido.Workspace.Deploy.SnapshotTest do
  use ExUnit.Case, async: true
  alias Jido.Workspace.Deploy.{Artifact, Snapshot}

  test "source identity stays separate from a verified deterministic digest" do
    entry = %{bytes: "hello", mode: 0o755}
    {:ok, a} = Snapshot.new(%{"bin/run" => entry}, id: "source-1")
    {:ok, b} = Snapshot.new(%{"bin/run" => entry}, id: "another-source")
    assert a.digest == b.digest
    assert a.id != b.id
    refute Snapshot.valid?(%{a | digest: "wrong"})
    assert {:error, :invalid_snapshot} = Snapshot.new(%{"../escape" => entry})
    assert {:error, :invalid_snapshot} = Snapshot.new(%{"a" => entry, "a/b" => entry})
    assert {:error, :invalid_snapshot} = Snapshot.new(%{123 => entry})
    assert {:error, :invalid_artifact} = Artifact.new(:source, "../escape", a)
  end

  test "projection refuses corrupted payloads, retains modes, and does not overwrite a release" do
    {:ok, sandbox} = Jido.Workspace.Sandbox.open()
    on_exit(fn -> Jido.Workspace.Sandbox.destroy(sandbox) end)
    {:ok, snapshot} = Snapshot.new(%{"bin/run" => %{bytes: "hello", mode: 0o755}})

    assert {:error, :digest_mismatch} =
             Snapshot.project(%{snapshot | digest: "wrong"}, sandbox, "bad")

    assert :ok = Snapshot.project(snapshot, sandbox, "release")
    assert :ok = Snapshot.verify(snapshot, Path.join(sandbox.root, "release"))
    assert {:error, :eexist} = Snapshot.project(snapshot, sandbox, "release")
    File.ln_s!("bin/run", Path.join(sandbox.root, "release/link"))

    assert {:error, {:unsupported_file, "link"}} =
             Snapshot.from_directory(Path.join(sandbox.root, "release"))
  end
end
