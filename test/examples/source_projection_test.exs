defmodule Jido.Workspace.Deploy.SourceProjectionTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Jido.Workspace.Deploy
  alias Jido.Workspace.Deploy.{Artifact, Recipe, Snapshot}

  test "files-only deployment has one writer; wait timeouts do not cancel work" do
    {:ok, sandbox} = Jido.Workspace.Sandbox.open()
    on_exit(fn -> Jido.Workspace.Sandbox.destroy(sandbox) end)

    {:ok, snapshot} =
      Snapshot.new(%{"index.txt" => %{bytes: "hello", mode: 0o644}}, id: "static-source")

    {:ok, artifact} = Artifact.new(:source, "1", snapshot)
    {:ok, target} = Deploy.source_target(sandbox, "static")
    {:ok, session} = Deploy.connect(target)
    assert {:error, :target_conflict} = Deploy.connect(%{target | name: "another-name"})
    recipe = %Recipe{prepare: [{"/bin/sleep", ["0.2"]}]}
    {:ok, plan} = Deploy.prepare(session, artifact, recipe: recipe)
    {:ok, other} = Deploy.prepare(session, artifact)
    {:ok, id} = Deploy.apply(session, plan)
    assert {:error, {:timeout, ^id}} = Deploy.await(session, id, 0)
    assert {:ok, ^id} = Deploy.apply(session, plan)
    assert {:error, :busy} = Deploy.apply(session, other)

    assert {:ok, %{status: :succeeded, evidence: %{state_policy: :files_only}}} =
             Deploy.await(session, id)

    assert File.read!(Path.join([sandbox.root, "static", "current", "index.txt"])) == "hello"

    assert {:error, :invalid_artifact_or_target_kind} =
             Deploy.prepare(session, %{artifact | version: "../escape"})

    assert {:error, :invalid_artifact_or_target_kind} =
             Deploy.prepare(session, artifact, preflight: {:x, :y, []})
  end

  test "preparation cannot replace captured source bytes" do
    {:ok, sandbox} = Jido.Workspace.Sandbox.open()
    on_exit(fn -> Jido.Workspace.Sandbox.destroy(sandbox) end)
    {:ok, snapshot} = Snapshot.new(%{"file" => %{bytes: "original", mode: 0o644}})
    {:ok, artifact} = Artifact.new(:source, "1", snapshot)
    {:ok, target} = Deploy.source_target(sandbox, "static")
    {:ok, session} = Deploy.connect(target)
    recipe = %Recipe{prepare: [{"/bin/sh", ["-c", "printf changed > file"]}]}
    {:ok, plan} = Deploy.prepare(session, artifact, recipe: recipe)
    {:ok, id} = Deploy.apply(session, plan)

    assert {:ok, %{status: :failed, evidence: %{reason: {:error, {:source_changed, "file"}}}}} =
             Deploy.await(session, id)

    assert {:ok, %{identity: %{current: nil}}} = Deploy.inspect(session)
  end
end
