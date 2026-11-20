Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.PinnedToolchainTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @moduletag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the pinned Python toolchain"
  end

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  import Jido.Workspace.Examples.LifecycleSupport

  @image "python@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e"
  @missing_image "python@sha256:" <> String.duplicate("0", 64)
  @program Path.join(__DIR__, "report.py")
  @draft "draft; Q4.txt"
  @result "build/report.txt"

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))
    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    python = %{profiles.docker | image: @image} |> Map.put(:tools, ["python3"])

    Application.put_env(
      :jido_workspace,
      :profiles,
      Map.merge(profiles, %{python: python, missing_python: %{python | image: @missing_image}})
    )

    :ok
  end

  test "Python runs in the requested directory and produces a portable report" do
    assert {id, 0} = docker(["image", "inspect", "--format", "{{.Id}}", @image])
    image_id = String.trim(id)
    assert {:ok, workspace} = Workspace.open(profile: :python)
    {_, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)

    snapshot =
      try do
        assert {:ok, %{capabilities: %{provider: :docker, image: ^image_id, network: :disabled}}} =
                 Workspace.info(workspace)

        assert :ok = Workspace.mkdir(workspace, "build")
        assert :ok = Workspace.write(workspace, "build/report.py", File.read!(@program))
        assert :ok = Workspace.write(workspace, "build/" <> @draft, "quarterly report\n")

        assert {:ok, %Execution{status: :exited, exit_status: 0, output: "Python 3.13.18\n"}} =
                 Workspace.run(workspace, ["python3", "report.py", @draft, "report.txt"],
                   cwd: "build"
                 )

        assert {:ok, "QUARTERLY REPORT\n"} = Workspace.read(workspace, @result)

        assert [container] = containers(sandbox)
        format = "{{.Config.Image}} {{.Config.WorkingDir}} {{.HostConfig.NetworkMode}}"
        assert {configuration, 0} = docker(["inspect", "--format", format, container])
        assert String.split(configuration) == [image_id, "/workspace/build", "none"]

        assert {:ok, snapshot} = Workspace.save(workspace)
        snapshot
      after
        assert :ok = Workspace.close(workspace)
      end

    assert containers(sandbox) == []
    refute File.exists?(sandbox.root)

    assert {:ok, restored} = Workspace.open(profile: :memory, from: snapshot)

    try do
      assert {:ok, "QUARTERLY REPORT\n"} = Workspace.read(restored, @result)
    after
      assert :ok = Workspace.close(restored)
    end
  end

  test "an unavailable pinned image returns an open error and leaves no root", %{tmp_dir: root} do
    {_, status} = docker(["image", "inspect", @missing_image])
    assert status != 0

    roots = Path.expand(Path.join(root, "sandboxes"))
    File.mkdir!(roots)
    previous = System.get_env("TMPDIR")
    System.put_env("TMPDIR", roots)

    try do
      assert {:error, %Error{code: :image_unavailable, operation: :open}} =
               Workspace.open(profile: :missing_python)

      assert File.ls!(roots) == []
    after
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end
  end
end
