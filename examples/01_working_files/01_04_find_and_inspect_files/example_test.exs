Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.FindProjectFilesTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Entry, Error, Execution}
  alias Jido.Workspace.Examples.FindProjectFiles
  import Jido.Workspace.Examples.LifecycleSupport, only: [await: 2, configure: 1, provider: 2]

  @marker "release [draft]"
  @note @marker <> "\n"
  @fixture [
    {".meta/notes.txt", @note},
    {"build/output.txt", @note},
    {"build-notes.txt", @note},
    {"src/.private.txt", @note},
    {"src/notes.txt", @note},
    {"src/routine.txt", "Routine note\n"},
    {"src/octet.bin", <<255>> <> @note},
    {"src/nul.bin", @note <> <<0>>}
  ]

  setup %{tmp_dir: root}, do: configure(root)

  test "memory applies profile settings to file discovery" do
    check_profiles(:memory)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run file discovery on Docker"
  end

  test "Docker applies the same profile settings to file discovery" do
    check_profiles(:docker)
  end

  test "a find keeps the file tree reserved until it finishes" do
    with_workspace(:memory, [], fn workspace ->
      assert :ok = Workspace.write(workspace, "notes.txt", @note)
      {_, memory} = provider(workspace, :memory)
      assert :ok = :sys.suspend(memory.lifetime)

      search =
        try do
          search = Task.async(fn -> Workspace.find(workspace, ".", contains: @marker) end)

          await(
            fn -> match?({:ok, %{phase: :finding}}, Workspace.info(workspace)) end,
            "The search did not reserve the tree"
          )

          assert {:error, %Error{code: :busy}} = Workspace.write(workspace, "notes.txt", "Later")
          search
        after
          assert :ok = :sys.resume(memory.lifetime)
        end

      assert {:ok, [%Entry{path: "notes.txt"}]} = Task.await(search)
      assert :ok = Workspace.write(workspace, "notes.txt", "Later")
    end)
  end

  test "profile validation refuses path traversal and root exclusions" do
    for exclude <- [["../outside"], ["/outside"], ["."]] do
      put_discovery(:invalid, :memory, %{exclude: exclude})
      assert {:error, %Error{code: :invalid_profile}} = Workspace.open(profile: :invalid)
    end
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check native links and special files"
  end

  test "Docker skips links and named pipes during a walk" do
    with_workspace(:docker, [], fn workspace ->
      assert :ok = Workspace.write(workspace, "src/notes.txt", @note)

      assert {:ok, %Execution{exit_status: 0}} =
               Workspace.run(workspace, [
                 "sh",
                 "-c",
                 "ln -s src linked && ln -s src/notes.txt duplicate.txt && mkfifo blocked"
               ])

      assert {:ok, [%Entry{path: "src/notes.txt"}]} = Workspace.find(workspace)

      assert {:ok, [%Entry{path: "src/notes.txt"}]} =
               Workspace.find(workspace, ".", contains: @marker)

      assert {:error, %Error{code: :symlink_path}} =
               Workspace.find(workspace, "linked", contains: @marker)
    end)
  end

  defp check_profiles(profile) do
    snapshot =
      with_workspace(profile, [], fn workspace ->
        for {path, bytes} <- @fixture do
          assert :ok = Workspace.write(workspace, path, bytes)
        end

        assert paths(Workspace.find(workspace, "src", contains: @marker)) == ["src/notes.txt"]
        assert {:ok, snapshot} = Workspace.save(workspace)
        snapshot
      end)

    put_discovery(:review, profile, %{exclude: ["build"]})

    with_workspace(:review, [from: snapshot], fn workspace ->
      assert paths(Workspace.find(workspace)) ==
               ~w(build-notes.txt src/notes.txt src/nul.bin src/octet.bin src/routine.txt)

      assert paths(Workspace.find(workspace, ".", contains: @marker)) ==
               ~w(build-notes.txt src/notes.txt)

      assert {:ok, []} = Workspace.find(workspace, "build")
      assert {:ok, []} = Workspace.find(workspace, ".meta", contains: @marker)
      assert {:ok, @note} = Workspace.read(workspace, "build/output.txt")
      assert {:ok, @note} = Workspace.read(workspace, "src/.private.txt")

      assert {:ok,
              %{entry: %Entry{path: "src/notes.txt", size: size}, bytes: @note, revision: rev}} =
               FindProjectFiles.inspect_first_match(workspace, "src", @marker)

      assert size == byte_size(@note)
      assert {:ok, @note, ^rev} = Workspace.read(workspace, "src/notes.txt", revision: true)
      assert {:ok, nil} = FindProjectFiles.inspect_first_match(workspace, "src", "Absent")
      assert {:error, %Error{code: :not_found}} = Workspace.find(workspace, "missing")
      assert {:error, %Error{code: :not_directory}} = Workspace.find(workspace, "src/notes.txt")
      assert {:error, %Error{code: :invalid_input}} = Workspace.find(workspace, "..")
      assert {:error, %Error{code: :invalid_input}} = Workspace.find(workspace, ".", contains: "")
    end)

    put_discovery(:all_files, profile, %{hidden: true, binary: true})

    with_workspace(:all_files, [from: snapshot], fn workspace ->
      assert paths(Workspace.find(workspace, ".", contains: @marker)) ==
               ~w(.meta/notes.txt build-notes.txt build/output.txt src/.private.txt src/notes.txt src/nul.bin src/octet.bin)

      assert paths(Workspace.find(workspace, "src", contains: <<255>>)) == ["src/octet.bin"]
    end)

    check_budget(profile, snapshot)
  end

  defp check_budget(profile, snapshot) do
    put_discovery(:small, profile, %{max_entries: 5, max_bytes: byte_size(@note)})

    with_workspace(:small, [from: snapshot], fn workspace ->
      assert {:error, %Error{code: :discovery_limit, details: %{cause: ":discovery_entry_limit"}}} =
               Workspace.find(workspace)

      assert paths(Workspace.find(workspace, "src")) ==
               ~w(src/notes.txt src/nul.bin src/octet.bin src/routine.txt)

      assert {:error, %Error{code: :discovery_limit, details: %{cause: ":discovery_byte_limit"}}} =
               Workspace.find(workspace, "src", contains: @marker)

      assert {:ok, @note} = Workspace.read(workspace, "src/notes.txt")
    end)
  end

  defp paths({:ok, entries}), do: Enum.map(entries, & &1.path)

  defp with_workspace(profile, opts, fun) do
    assert {:ok, workspace} = Workspace.open([profile: profile] ++ opts)

    try do
      fun.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp put_discovery(name, provider, discovery) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    profile =
      Map.merge(Map.fetch!(profiles, provider), %{policy: :read_only, discovery: discovery})

    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, name, profile))
  end
end
