Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.DeploySavedTreeTest do
  use ExUnit.Case, async: false

  alias Jido.Workspace
  alias Jido.Workspace.{Deploy, Sandbox}
  alias Jido.Workspace.Deploy.{Artifact, Recipe, Snapshot}
  alias Jido.Workspace.Examples.LifecycleSupport

  @moduletag :integration
  @moduletag :tmp_dir

  @report_path "bin/report; v1.txt"
  @bytes <<0, 10, 255>>

  setup %{tmp_dir: root} do
    store = Path.join(root, "snapshots")
    LifecycleSupport.configure(store)
    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    Application.put_env(
      :jido_workspace,
      :profiles,
      Map.merge(profiles, %{
        reader: %{profiles.memory | policy: :read_only},
        import_only: %{profiles.memory | policy: [:import]},
        read_only_without_import: %{profiles.memory | policy: [:read]},
        other_store: %{profiles.memory | policy: :read_only, store: "other"}
      })
    )

    Application.put_env(:jido_workspace, :stores, %{"reports" => store, "other" => store})
    %{store: store}
  end

  test "the saved memory tree deploys after the source changes and closes" do
    reference = save_then_edit(:memory)
    assert {:ok, payload} = Snapshot.from_saved(transfer(reference), profile: :reader)
    assert payload.entries == %{@report_path => %{bytes: @bytes, mode: 0o644}}
    assert payload.directories == ["bin", "var", "var/empty"]
    refute Snapshot.valid?(%{payload | directories: ["bin", "var"]})
    refute Snapshot.valid?(%{payload | directories: ["bin" | :invalid]})

    {sandbox, target, session} = connect_target([])

    assert %{status: :succeeded, snapshot_id: ^reference, digest: digest} =
             deploy(session, payload)

    assert digest == payload.digest

    release = deployed_path(sandbox, target)
    assert {:ok, @bytes} == Sandbox.read(sandbox, Path.join(release, @report_path))
    assert {:error, :enoent} == Sandbox.read(sandbox, Path.join(release, "draft.txt"))
    assert :ok == Snapshot.verify(payload, Path.join(sandbox.root, release))

    assert :ok == Sandbox.mkdir(sandbox, Path.join(release, "extra"))

    assert {:error, :content_mismatch} ==
             Snapshot.verify(payload, Path.join(sandbox.root, release))
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to test a Docker source and target"
  end

  test "the same handoff preserves executability from a Docker source to a Docker target" do
    reference = save_then_edit(:docker)
    assert {:ok, payload} = Snapshot.from_saved(transfer(reference), profile: :reader)
    assert %{mode: 0o755} = payload.entries["bin/check.sh"]

    image = System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest")
    {sandbox, target, session} = connect_target(provider: :docker, image: image)

    recipe = %Recipe{verify: {"sh", ["-c", "test -d var/empty && bin/check.sh"]}}

    assert %{
             status: :succeeded,
             snapshot_id: ^reference,
             evidence: %{state_policy: :files_only, verification: [%{output: "saved runner\n"}]}
           } = deploy(session, payload, recipe: recipe)

    release = deployed_path(sandbox, target)
    assert {:ok, @bytes} == Sandbox.read(sandbox, Path.join(release, @report_path))
    assert :ok == Snapshot.verify(payload, Path.join(sandbox.root, release))
  end

  test "only a valid bundle in the reader's authorized store can become a deploy payload", %{
    store: store
  } do
    reference = save_then_edit(:memory)
    assert {:ok, %Snapshot{id: ^reference}} = Snapshot.from_saved(reference, profile: :reader)

    assert {:error, {:policy_denied, :read}} =
             Snapshot.from_saved(reference, profile: :import_only)

    assert {:error, {:policy_denied, :import}} =
             Snapshot.from_saved(reference, profile: :read_only_without_import)

    assert {:error, {:policy_denied, :import}} =
             Snapshot.from_saved(reference, profile: :other_store)

    bundle = Path.join(store, reference.digest)
    File.write!(bundle, "[]")
    assert {:error, :invalid_snapshot} = Snapshot.from_saved(reference, profile: :reader)

    File.rm!(bundle)
    assert {:error, :not_found} = Snapshot.from_saved(reference, profile: :reader)
  end

  test "preparation cannot remove or rename a saved empty directory" do
    reference = save_then_edit(:memory)
    assert {:ok, payload} = Snapshot.from_saved(reference, profile: :reader)
    {sandbox, target, session} = connect_target([])
    assert %{status: :succeeded, evidence: %{current: current}} = deploy(session, payload)

    for command <- ["rmdir var/empty", "mv var/empty var/temp && mv var/temp var/EMPTY"] do
      recipe = %Recipe{prepare: [{"/bin/sh", ["-c", command]}]}

      assert %{
               status: :failed,
               evidence: %{phase: :prepare, reason: {:error, {:source_changed, "var/empty"}}}
             } = deploy(session, payload, recipe: recipe)

      assert {:ok, ^current} = Sandbox.read_link(sandbox, Path.join(target.path, "current"))
    end
  end

  defp save_then_edit(profile) do
    assert {:ok, workspace} = Workspace.open(profile: profile)

    try do
      assert :ok = Workspace.mkdir(workspace, "bin")
      assert :ok = Workspace.mkdir(workspace, "var")
      assert :ok = Workspace.mkdir(workspace, "var/empty")
      assert :ok = Workspace.write(workspace, @report_path, @bytes)

      if profile == :docker do
        assert :ok =
                 Workspace.write(
                   workspace,
                   "bin/check.sh",
                   "#!/bin/sh\nprintf 'saved runner\\n'\n"
                 )

        assert {:ok, %{exit_status: 0}} =
                 Workspace.run(workspace, ["chmod", "+x", "bin/check.sh"])
      end

      assert {:ok, reference} = Workspace.save(workspace)
      assert :ok = Workspace.write(workspace, @report_path, "revised bytes")
      assert :ok = Workspace.write(workspace, "draft.txt", "unsaved")
      assert :ok = Workspace.delete(workspace, "var/empty")
      reference
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp transfer(reference), do: reference |> Jason.encode!() |> Jason.decode!()

  defp connect_target(opts) do
    assert {:ok, sandbox} = Sandbox.open(Keyword.put(opts, :owner, self()))
    assert {:ok, target} = Deploy.source_target(sandbox, "report")
    assert {:ok, session} = Deploy.connect(target)
    {sandbox, target, session}
  end

  defp deploy(session, payload, opts \\ []) do
    assert {:ok, artifact} = Artifact.new(:source, "1", payload)
    assert {:ok, plan} = Deploy.prepare(session, artifact, opts)
    assert {:ok, operation_id} = Deploy.apply(session, plan)
    assert {:ok, record} = Deploy.await(session, operation_id)
    record
  end

  defp deployed_path(sandbox, target) do
    assert {:ok, current} = Sandbox.read_link(sandbox, Path.join(target.path, "current"))
    Path.join(target.path, current)
  end
end
