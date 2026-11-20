Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.EditKnownRevisionTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Entry, Error, Execution}
  alias Jido.Workspace.Examples.EditKnownRevision
  import Jido.Workspace.Examples.LifecycleSupport, only: [configure: 1]

  @path "draft.txt"
  @original "Original\n"
  @command_edit "Reviewed\n"

  setup %{tmp_dir: root}, do: configure(root)

  test "memory rejects stale edits and checks revisions after commands" do
    check_revisions(:memory)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check revisions on Docker"
  end

  test "Docker rejects stale edits and checks revisions after commands" do
    check_revisions(:docker)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check native file types and metadata"
  end

  test "native edits replace the specified hard link and preserve its mode" do
    assert {:ok, workspace} = Workspace.open(profile: :docker)

    try do
      assert :ok = Workspace.write(workspace, @path, @original)
      assert {:ok, %Execution{exit_status: 0}} = Workspace.run(workspace, ["chmod", "700", @path])

      assert {:ok, %Execution{exit_status: 0}} =
               Workspace.run(workspace, ["ln", @path, "copy.txt"])

      assert {:ok, @original, revision} = Workspace.read(workspace, "copy.txt", revision: true)
      assert :ok = Workspace.write(workspace, "copy.txt", @command_edit, expected: revision)
      assert {:ok, @original} = Workspace.read(workspace, @path)
      assert {:ok, @command_edit} = Workspace.read(workspace, "copy.txt")

      assert {:ok, [%Entry{path: "copy.txt", mode: :executable}, %Entry{path: @path}]} =
               Workspace.list(workspace)

      assert {:ok, %Execution{exit_status: 0}} =
               Workspace.run(workspace, ["sh", "-c", "ln -s draft.txt link.txt && mkfifo pipe"])

      assert {:error, %Error{code: :symlink_path}} =
               Workspace.write(workspace, "link.txt", "Rejected", expected: revision)

      assert {:error, %Error{code: :unsupported_capability}} =
               Workspace.read(workspace, "pipe", revision: true)

      assert {:error, %Error{code: :unsupported_capability}} =
               Workspace.write(workspace, "pipe", "Rejected", expected: revision)
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp check_revisions(profile) do
    assert {:ok, workspace} = Workspace.open(profile: profile)

    snapshot =
      try do
        assert :ok = Workspace.write(workspace, @path, @original)
        check_concurrent_edits(workspace)

        assert {:ok, _, before_command} = Workspace.read(workspace, @path, revision: true)
        assert :ok = Workspace.write(workspace, "incoming.txt", @command_edit)

        assert {:ok, %Execution{exit_status: 0}} =
                 Workspace.run(workspace, ["cp", "incoming.txt", @path])

        assert {:error, %Error{code: :stale_revision}} =
                 Workspace.write(workspace, @path, "Rejected", expected: before_command)

        assert {:ok, @command_edit, current} = Workspace.read(workspace, @path, revision: true)

        assert {:error, %Error{code: :invalid_input}} =
                 Workspace.write(workspace, @path, "Rejected", expected: "invalid")

        assert {:error, %Error{code: :invalid_input}} =
                 Workspace.write(workspace, "../draft.txt", "Rejected", expected: current)

        assert {:ok, snapshot} = Workspace.save(workspace)
        assert :ok = Workspace.delete(workspace, @path)

        assert {:error, %Error{code: :stale_revision}} =
                 Workspace.write(workspace, @path, "Rejected", expected: current)

        assert {:error, %Error{code: :not_found}} =
                 Workspace.read(workspace, @path, revision: true)

        assert :ok = Workspace.mkdir(workspace, @path)

        assert {:error, %Error{code: :is_directory}} =
                 Workspace.write(workspace, @path, "Rejected", expected: current)

        assert {:ok, []} = Workspace.list(workspace, @path)
        snapshot
      after
        assert :ok = Workspace.close(workspace)
      end

    check_policy(profile, snapshot)
  end

  defp check_concurrent_edits(workspace) do
    reviewer = self()
    barrier = make_ref()

    edits =
      for text <- ["Editor A\n", "Editor B\n"] do
        task =
          Task.async(fn ->
            EditKnownRevision.edit(workspace, @path, fn current ->
              send(reviewer, {self(), :read, current})

              receive do
                ^barrier -> text
              end
            end)
          end)

        {task, text}
      end

    for {%Task{pid: pid}, _} <- edits do
      assert_receive {^pid, :read, @original}, 5_000
    end

    for {task, _} <- edits, do: send(task.pid, barrier)

    results = Enum.map(edits, fn {task, text} -> {Task.await(task, 10_000), text} end)
    assert [winner] = for({:ok, text} <- results, do: text)

    assert [%Error{code: :stale_revision, operation: :write}] =
             for({{:error, error}, _} <- results, do: error)

    assert {:ok, ^winner} = Workspace.read(workspace, @path)

    assert :ok = EditKnownRevision.edit(workspace, @path, &[&1, "Follow-up\n"])
    assert {:ok, winner <> "Follow-up\n"} == Workspace.read(workspace, @path)
  end

  defp check_policy(profile, snapshot) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    read_only = %{Map.fetch!(profiles, profile) | policy: :read_only}
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, :reader, read_only))

    assert {:ok, workspace} = Workspace.open(profile: :reader, from: snapshot)

    try do
      assert {:ok, @command_edit, revision} = Workspace.read(workspace, @path, revision: true)

      assert {:error, %Error{code: :policy_denied}} =
               Workspace.write(workspace, @path, "Rejected", expected: revision)
    after
      assert :ok = Workspace.close(workspace)
    end
  end
end
