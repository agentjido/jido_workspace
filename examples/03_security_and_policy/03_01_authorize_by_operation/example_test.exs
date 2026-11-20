Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.PublishReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution, Info}
  alias Jido.Workspace.Examples.PublishReport
  import Jido.Workspace.Examples.LifecycleSupport, only: [configure: 1]

  @path "report.txt"
  @report "Reviewed report\n"

  setup %{tmp_dir: root}, do: configure(Path.join(root, "snapshots"))

  test "memory can grant import, read, edit, execute, and save separately" do
    check_permissions(:memory)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the same grants on Docker"
  end

  test "Docker can grant import, read, edit, execute, and save separately" do
    check_permissions(:docker)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the read-only checkout mount"
  end

  test "an inspector and a publisher can use a borrowed Docker checkout without editing it", %{
    tmp_dir: root
  } do
    checkout = Path.join(root, "checkout")
    File.mkdir!(checkout)
    File.write!(Path.join(checkout, @path), @report)
    put_profile(:viewer, :docker, [:read, :execute], %{checkout: checkout})
    put_profile(:publisher, :docker, [:read, :save], %{checkout: checkout})

    with_workspace(:viewer, [], fn workspace ->
      check_read_only_execution(workspace, :docker)
    end)

    snapshot =
      with_workspace(:publisher, [], fn workspace ->
        assert {:ok, %{report: @report, snapshot: snapshot}} =
                 PublishReport.publish(workspace, @path)

        snapshot
      end)

    with_workspace(:memory, [from: snapshot], fn workspace ->
      assert {:ok, @report} = Workspace.read(workspace, @path)
    end)

    assert File.ls!(checkout) == [@path]
    assert File.read!(Path.join(checkout, @path)) == @report
  end

  test "invalid grant lists fail at open" do
    for grants <- [[:read, :read], [:read, :unknown], [:read, :raw_handle], [:execute]] do
      put_profile(:invalid, :memory, grants)

      assert {:error, %Error{code: :invalid_profile, operation: :open}} =
               Workspace.open(profile: :invalid)
    end
  end

  defp check_permissions(provider) do
    snapshot =
      with_workspace(provider, [], fn workspace ->
        assert :ok = Workspace.write(workspace, @path, @report)
        assert {:ok, snapshot} = Workspace.save(workspace)
        snapshot
      end)

    put_profile(:editor, provider, [:import, :read, :write])
    put_profile(:inspector, provider, [:import, :read, :execute], %{tools: ["cat", "cp"]})
    put_profile(:builder, provider, [:import, :read, :write, :execute])
    put_profile(:publisher, provider, [:import, :read, :save])
    put_profile(:import_only, provider, [:import])
    put_profile(:fresh, provider, [:read])
    put_profile(:other_store, provider, [:import, :read], %{store: "other"})

    from = [from: snapshot]

    with_workspace(:editor, from, fn workspace ->
      assert {:ok, @report} = Workspace.read(workspace, @path)
      assert :ok = Workspace.write(workspace, @path, "New edits\n")
      assert_denied(Workspace.run(workspace, ["cat", @path]), :run, :execute)
      assert_denied(Workspace.save(workspace), :save, :save)
    end)

    with_workspace(:inspector, from, fn workspace ->
      assert {:ok, %Info{policy: [:import, :read, :execute]}} = Workspace.info(workspace)
      check_read_only_execution(workspace, provider)
    end)

    with_workspace(:builder, from, fn workspace ->
      assert {:ok, %Execution{exit_status: 0}} =
               Workspace.run(workspace, ["cp", @path, "copy.txt"])

      assert {:ok, @report} = Workspace.read(workspace, "copy.txt")
      assert_denied(Workspace.save(workspace), :save, :save)
    end)

    with_workspace(:publisher, from, fn workspace ->
      assert_denied(Workspace.write(workspace, @path, "Edit"), :write, :write)
      assert_denied(Workspace.run(workspace, ["cat", @path]), :run, :execute)

      assert {:ok, %{report: @report, snapshot: ^snapshot}} =
               PublishReport.publish(workspace, @path)
    end)

    with_workspace(:import_only, from, fn workspace ->
      assert_denied(Workspace.read(workspace, @path), :read, :read)
    end)

    with_workspace(:fresh, [], fn workspace ->
      assert {:ok, []} = Workspace.list(workspace)
    end)

    assert_denied(Workspace.open([profile: :fresh] ++ from), :open, :import)
    assert_denied(Workspace.open(profile: :fresh, from: %{}), :open, :import)
    assert_denied(Workspace.open([profile: :other_store] ++ from), :open, :import)
  end

  defp check_read_only_execution(workspace, provider) do
    assert {:ok, %Execution{exit_status: 0, output: @report}} =
             Workspace.run(workspace, ["cat", @path])

    assert_denied(Workspace.write(workspace, @path, "Edit"), :write, :write)

    source = Stream.map([@report], fn _ -> flunk("A denied write read its source") end)
    assert_denied(Workspace.write_stream(workspace, @path, source), :write_stream, :write)

    result = Workspace.run(workspace, ["cp", @path, "copy.txt"])
    assert_command_write_denied(result, provider)

    assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "copy.txt")
    assert {:ok, @report} = Workspace.read(workspace, @path)
  end

  defp assert_command_write_denied(result, :memory), do: assert_denied(result, :run, :execute)

  defp assert_command_write_denied(result, :docker) do
    assert {:ok, %Execution{status: :exited, exit_status: code}} = result
    assert code > 0
  end

  defp assert_denied(result, operation, action) do
    assert {:error,
            %Error{code: :policy_denied, operation: ^operation, details: %{action: ^action}}} =
             result
  end

  defp put_profile(name, provider, grants, options \\ %{}) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    profile = profiles |> Map.fetch!(provider) |> Map.put(:policy, grants) |> Map.merge(options)
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, name, profile))
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
