defmodule Jido.Workspace.BoundariesTest do
  use ExUnit.Case, async: false
  alias Jido.Workspace
  alias Jido.Workspace.{Sandbox, Deploy}
  alias Jido.Workspace.Deploy.{Artifact, Snapshot}

  test "path aliases and concurrent connects use one deployment controller" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    {:ok, target} = Deploy.source_target(sandbox, "app")
    {:ok, session} = Deploy.connect(target)
    assert {:ok, ^session} = Deploy.connect(%{target | path: "./app/."})

    results =
      1..12
      |> Task.async_stream(fn _ -> Deploy.connect(%{target | path: "app/"}) end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, {:ok, session}}))
    assert {:error, :target_conflict} = Deploy.connect(%{target | name: "different"})
    {:ok, location} = Sandbox.location(sandbox, "./app")
    assert target.id == location.id

    # Case aliases must also share identity when the provider filesystem accepts them.
    if File.dir?(Path.join(sandbox.root, "APP")) do
      assert {:ok, ^session} = Deploy.connect(%{target | path: "APP"})
    end

    File.ln_s!("app", Path.join(sandbox.root, "alias"))
    assert {:error, :symlink_path} = Deploy.connect(%{target | path: "alias"})
  end

  test "target file operations use the controller root, not mutable handle fields" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    fake = %{sandbox | root: Path.join(sandbox.root, "wrong-root"), id: "wrong-id"}
    {:ok, target} = Deploy.source_target(fake, "app", path: "./app")
    assert target.sandbox == sandbox
    assert {:error, :invalid_path} = Sandbox.replace_link(fake, "app/current", "/tmp", "id")
    assert {:error, :invalid_path} = Sandbox.replace_link(fake, "app/current", "../escape", "id")
    {:ok, session} = Deploy.connect(target)
    {:ok, snapshot} = Snapshot.new(%{"input" => %{bytes: "expected", mode: 0o644}})
    {:ok, artifact} = Artifact.new(:source, "1", snapshot)
    {:ok, plan} = Deploy.prepare(session, artifact)
    {:ok, id} = Deploy.apply(session, plan)
    assert {:ok, %{status: :succeeded}} = Deploy.await(session, id)
    assert {:ok, "releases/" <> ^id} = Sandbox.read_link(fake, "app/current")
    assert {:ok, "expected"} = Sandbox.read(fake, "app/releases/#{id}/input")
    refute File.exists?(fake.root)
  end

  test "Sandbox file operations enforce policy and refuse traversal" do
    {:ok, sandbox} = Sandbox.open(policy: :read_only)
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    assert {:error, {:policy_denied, :write}} = Sandbox.mkdir(sandbox, "app")

    assert {:error, {:policy_denied, :write}} =
             Sandbox.replace_link(sandbox, "current", "release", "id")

    assert {:error, :invalid_path} = Sandbox.read(sandbox, "../outside")
    assert {:error, :invalid_path} = Sandbox.read_link(sandbox, "../outside")
  end

  test "Workspace commands record the observed view and reject stale revisions" do
    {:ok, workspace} = Workspace.open()
    on_exit(fn -> Workspace.close(workspace) end)
    :ok = Workspace.write(workspace, "/input", "one")
    {:ok, view} = Workspace.file_view(workspace)
    assert view.kind == :workspace

    assert {:ok, %{output: "one", files: ^view}} =
             Workspace.run(workspace, "cat /input", files: view)

    :ok = Workspace.write(workspace, "/input", "two")

    assert {:error, %Jido.Workspace.Error{code: :stale_file_view}} =
             Workspace.run(workspace, "write /marker bad", files: view)

    assert {:error, %Jido.Workspace.Error{code: :not_found}} =
             Workspace.read(workspace, "/marker")

    {:ok, before} = Workspace.file_view(workspace)
    {:ok, next} = Workspace.run(workspace, "write /input three", files: before)
    assert next.files == before
    after_view = next.after_files
    refute after_view.revision == before.revision
  end

  @tag :tmp_dir
  test "adapters without a revision report that limit and refuse a pinned view", %{tmp_dir: root} do
    {:ok, workspace} =
      Workspace.open(adapter: Jido.VFS.Adapter.Local, adapter_opts: [prefix: root])

    on_exit(fn -> Workspace.close(workspace) end)
    {:ok, view} = Workspace.file_view(workspace)
    assert view.revision == :unavailable

    assert {:error, %Jido.Workspace.Error{code: :unversioned_file_view}} =
             Workspace.run(workspace, "pwd", files: view)

    assert {:ok, %{files: ^view}} = Workspace.run(workspace, "pwd", files: :current)
  end

  test "Workspace and Sandbox revisions cannot be substituted" do
    {:ok, workspace} = Workspace.open()
    {:ok, sandbox} = Sandbox.open()

    on_exit(fn ->
      Workspace.close(workspace)
      Sandbox.destroy(sandbox)
    end)

    {:ok, view} = Workspace.file_view(workspace)
    assert {:error, :stale_file_view} = Sandbox.exec(sandbox, "/bin/echo", ["bad"], files: view)
    {:ok, view} = Sandbox.file_view(sandbox)

    assert {:error, %Jido.Workspace.Error{code: :stale_file_view}} =
             Workspace.run(workspace, "pwd", files: view)
  end
end
