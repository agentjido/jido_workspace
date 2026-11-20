Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.RootedReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Entry, Error, Execution}
  alias Jido.Workspace.Examples.RootedReport
  import Jido.Workspace.Examples.LifecycleSupport, only: [configure: 1]

  @report_path "reports/-report.txt"
  @report "Workspace report\n"
  @outside "Host fixture\n"

  setup %{tmp_dir: root}, do: configure(Path.join(root, "snapshots"))

  test "memory accepts canonical relative paths and refuses ambiguous paths", %{tmp_dir: root} do
    check_relative_paths(:memory, root)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the same paths on Docker"
  end

  test "Docker accepts the same relative paths and refuses ambiguous paths", %{tmp_dir: root} do
    check_relative_paths(:docker, root)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check native symbolic links"
  end

  test "file calls refuse symbolic links and Docker does not mount their host targets", %{
    tmp_dir: root
  } do
    {checkout, outside} = prepare_checkout(root)
    :ok = File.ln_s(outside, Path.join(checkout, "linked-file.txt"))
    :ok = File.ln_s(Path.dirname(outside), Path.join(checkout, "linked-directory"))

    snapshot =
      with_workspace(:checkout, [], fn workspace ->
        assert_denied(Workspace.read(workspace, "linked-file.txt"), :read, :symlink_path)

        assert_denied(
          Workspace.read_chunk(workspace, "linked-file.txt", 0, 64),
          :read_chunk,
          :symlink_path
        )

        assert_denied(
          Workspace.read(workspace, "linked-directory/fixture.txt"),
          :read,
          :symlink_path
        )

        assert_denied(
          Workspace.write(workspace, "linked-file.txt", "Rejected"),
          :write,
          :symlink_path
        )

        assert_denied(Workspace.mkdir(workspace, "linked-directory/new"), :mkdir, :symlink_path)
        assert_denied(Workspace.delete(workspace, "linked-file.txt"), :delete, :symlink_path)

        source = Stream.map([@report], fn _ -> flunk("The rejected write read its source") end)

        assert_denied(
          Workspace.write_stream(workspace, "linked-file.txt", source),
          :write_stream,
          :symlink_path
        )

        assert_denied(
          Workspace.run(workspace, ["pwd"], cwd: "linked-directory"),
          :run,
          :symlink_path
        )

        assert_denied(Workspace.list(workspace), :list, :unsupported_capability)
        assert_denied(Workspace.save(workspace), :save, :unsupported_capability)

        assert {:ok, []} = Workspace.find(workspace, ".", contains: @outside)

        for link <- ["linked-file.txt", "linked-directory/fixture.txt"] do
          assert {:ok, %Execution{status: :exited, exit_status: code, output: output}} =
                   Workspace.run(workspace, ["cat", link])

          assert code > 0
          refute output =~ @outside
        end

        assert {:ok, %Execution{exit_status: 0}} =
                 Workspace.run(workspace, ["rm", "linked-file.txt", "linked-directory"])

        assert :ok = Workspace.write(workspace, @report_path, @report)
        assert {:ok, snapshot} = Workspace.save(workspace)
        snapshot
      end)

    assert File.read!(outside) == @outside
    refute File.exists?(Path.join(Path.dirname(outside), "new"))

    with_workspace(:memory, [from: snapshot], fn workspace ->
      assert {:ok, @report} = Workspace.read(workspace, @report_path)
    end)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check native hard links"
  end

  test "writes and deletes change only the specified hard-link entry", %{tmp_dir: root} do
    {checkout, outside} = prepare_checkout(root)
    File.chmod!(outside, 0o755)

    for name <- ["edit.txt", "keep.txt", "remove.txt"] do
      :ok = File.ln(outside, Path.join(checkout, name))
    end

    with_workspace(:checkout, [], fn workspace ->
      assert {:ok, @outside} = Workspace.read(workspace, "edit.txt")
      assert :ok = Workspace.write(workspace, "edit.txt", @report)
      assert {:ok, @report} = Workspace.read(workspace, "edit.txt")
      assert {:ok, @outside} = Workspace.read(workspace, "keep.txt")
      assert File.read!(outside) == @outside

      assert :ok = Workspace.delete(workspace, "remove.txt")
      assert_denied(Workspace.read(workspace, "remove.txt"), :read, :not_found)
      assert {:ok, @outside} = Workspace.read(workspace, "keep.txt")

      assert {:ok, [%Entry{path: "edit.txt", mode: :executable}, %Entry{path: "keep.txt"}]} =
               Workspace.list(workspace)
    end)

    assert File.read!(outside) == @outside
  end

  defp check_relative_paths(profile, root) do
    outside = Path.join(root, "fixture.txt")
    File.write!(outside, @outside)

    with_workspace(profile, [], fn workspace ->
      assert :ok = Workspace.write(workspace, @report_path, @report)

      for path <- [
            outside,
            "../fixture.txt",
            "reports/../fixture.txt",
            "reports//-report.txt",
            "reports\\-report.txt",
            "C:fixture.txt"
          ] do
        assert_denied(Workspace.read(workspace, path), :read, :invalid_input)
        assert_denied(Workspace.write(workspace, path, "Rejected"), :write, :invalid_input)
        assert_denied(Workspace.move(workspace, @report_path, path), :move, :invalid_input)
        assert_denied(Workspace.run(workspace, ["pwd"], cwd: path), :run, :invalid_input)
      end

      assert {:ok, %{report: @report, execution: %Execution{exit_status: 0, output: @report}}} =
               RootedReport.read_with_tool(workspace, @report_path)
    end)

    assert File.read!(outside) == @outside
  end

  defp prepare_checkout(root) do
    checkout = Path.join(root, "checkout")
    outside = Path.join([root, "host", "fixture.txt"])
    File.mkdir!(checkout)
    File.mkdir!(Path.dirname(outside))
    File.write!(outside, @outside)

    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    checkout_profile = Map.put(profiles.docker, :checkout, checkout)

    Application.put_env(
      :jido_workspace,
      :profiles,
      Map.put(profiles, :checkout, checkout_profile)
    )

    {checkout, outside}
  end

  defp assert_denied(result, operation, code) do
    assert {:error, %Error{code: ^code, operation: ^operation}} = result
  end

  defp with_workspace(name, opts, fun) do
    assert {:ok, workspace} = Workspace.open([profile: name] ++ opts)

    try do
      fun.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end
end
