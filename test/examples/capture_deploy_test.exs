defmodule Jido.Workspace.Deploy.CaptureDeployTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Jido.VFS
  alias Jido.VFS.Adapter.InMemory
  alias Jido.Workspace.Deploy
  alias Jido.Workspace.Deploy.{Artifact, Snapshot}
  alias Jido.Workspace.Deploy.Test.NodeApp
  alias Jido.Workspace.Sandbox

  test "fixed memory captures deploy and recover independently of live edits" do
    fs = InMemory.configure(name: make_ref())
    {:ok, storage} = InMemory.start_link(fs)
    on_exit(fn -> if Process.alive?(storage), do: GenServer.stop(storage) end)
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    {:ok, target} = Deploy.source_target(sandbox, "memory-app")
    {:ok, session} = Deploy.connect(target)
    port = NodeApp.port()
    recipe = NodeApp.recipe(port)

    put_source(fs, NodeApp.artifact(1))
    :ok = VFS.write(fs, "only-v1.txt", "retained in the saved capture")
    {:ok, saved, token} = VFS.capture(fs)

    changes = source_edits(NodeApp.artifact(2, bad_verify: true)) ++ [{:delete, "only-v1.txt"}]
    assert {:ok, _} = VFS.apply_edits(fs, token, changes)
    {:ok, candidate, _} = VFS.capture(fs)
    :ok = VFS.write(fs, "server.js", "unaccepted draft: not valid JavaScript")
    :ok = VFS.write(fs, "draft.txt", "must not be deployed")

    {:ok, original} = Snapshot.from_capture(saved, id: "accepted-memory-1")
    {:ok, changed} = Snapshot.from_capture(candidate, id: "candidate-memory-2")
    refute original.digest == changed.digest
    {:ok, a} = Artifact.new(:source, "1", original)
    {:ok, b} = Artifact.new(:source, "2", changed)

    {:ok, plan} = Deploy.prepare(session, a, recipe: recipe)
    {:ok, first_id} = Deploy.apply(session, plan)
    assert {:ok, %{status: :succeeded} = first} = Deploy.await(session, first_id)
    assert first.snapshot_id == original.id
    assert first.digest == original.digest
    assert hd(first.evidence.verification).output =~ ~s("version":1)
    assert NodeApp.get(port, "/add") =~ ~s("count":1)
    assert :ok = Snapshot.verify(original, release_path(sandbox, target, first_id))
    refute File.exists?(Path.join(release_path(sandbox, target, first_id), "draft.txt"))

    {:ok, plan} = Deploy.prepare(session, b, recipe: recipe)
    {:ok, failed_id} = Deploy.apply(session, plan)
    assert {:ok, %{status: :recovery_required} = failed} = Deploy.await(session, failed_id)
    assert failed.snapshot_id == changed.id
    assert failed.digest == changed.digest
    assert NodeApp.get(port) =~ ~s("version":2)
    assert {:ok, %{controller: %{blocked: true}}} = Deploy.inspect(session)
    {:ok, ordinary} = Deploy.prepare(session, a, recipe: recipe)
    assert {:error, :recovery_required} = Deploy.apply(session, ordinary)

    GenServer.stop(storage)
    assert {:ok, ^original} = Snapshot.from_capture(saved, id: original.id)
    {:ok, recovery} = Deploy.recover(session, failed_id, a, recipe: recipe)
    {:ok, recovery_id} = Deploy.apply(session, recovery)
    assert recovery_id != first_id

    assert {:ok, %{status: :succeeded, recovery_of: ^failed_id} = restored} =
             Deploy.await(session, recovery_id)

    assert restored.digest == original.digest
    assert restored.snapshot_id == original.id
    assert NodeApp.get(port) =~ ~s("version":1,"count":0)
    assert :ok = Snapshot.verify(original, release_path(sandbox, target, recovery_id))
    assert {:ok, %{controller: %{blocked: false}}} = Deploy.inspect(session)
    assert {:ok, %{status: :recovery_required}} = Deploy.status(session, failed_id)
  end

  defp put_source(fs, artifact) do
    for {:write, path, bytes} <- source_edits(artifact), do: :ok = VFS.write(fs, path, bytes)
  end

  defp source_edits(artifact),
    do: Enum.map(artifact.snapshot.entries, fn {path, entry} -> {:write, path, entry.bytes} end)

  defp release_path(sandbox, target, id),
    do: Path.join([sandbox.root, target.path, "releases", id])
end
