Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.ReadWithApprovedToolTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution, Info}
  alias Jido.Workspace.Examples.ReadWithApprovedTool

  import Jido.Workspace.Examples.LifecycleSupport,
    only: [clean_up_docker_on_failure: 1, configure: 1, containers: 1, provider: 2]

  @path "report.txt"
  @report "Approved report\n"
  @missing "/jido-example-missing-tool"

  setup %{tmp_dir: root}, do: configure(Path.join(root, "snapshots"))

  test "memory runs an approved tool and refuses other entrypoints" do
    check_allowlist(:memory)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check tool policy on Docker"
  end

  test "Docker runs the same approved tool and refuses other entrypoints" do
    check_allowlist(:docker)
  end

  test "memory refuses a profile that names a tool outside its virtual tool set" do
    put_profile(:memory, ["cat", @missing])

    assert {:error, %Error{code: :invalid_profile, operation: :open}} =
             Workspace.open(profile: :review)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check a missing executable on Docker"
  end

  test "Docker cleans up a failed start and allows the caller to edit and run again" do
    put_profile(:docker, ["cat", "sh", @missing])

    with_workspace(fn workspace ->
      {_, sandbox} = provider(workspace, :native)
      clean_up_docker_on_failure(sandbox)

      assert {:error, %Error{code: :start_failed, operation: :run, details: %{execution_id: id}}} =
               ReadWithApprovedTool.read(workspace, @missing, @path)

      assert is_binary(id)
      assert containers(sandbox) == []
      assert {:ok, %Info{phase: :ready, active_execution_id: nil}} = Workspace.info(workspace)
      assert :ok = Workspace.write(workspace, @path, @report)
      assert {:ok, %{kind: "snapshot"}} = Workspace.save(workspace)
      assert {:ok, @report} = ReadWithApprovedTool.read(workspace, "cat", @path)

      assert {:ok, %Execution{status: :exited, exit_status: 127}} =
               Workspace.run(workspace, ["sh", "-c", "exit 127"])
    end)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the write fence after failed cleanup"
  end

  test "Docker keeps writes and saves blocked while cleanup is unconfirmed", %{tmp_dir: root} do
    put_profile(:docker, [@missing])
    hold = hold_removal(root)

    sandbox =
      with_workspace(fn workspace ->
        {_, sandbox} = provider(workspace, :native)
        clean_up_docker_on_failure(sandbox)

        try do
          assert {:error, %Error{code: :quiescence_unknown}} =
                   Workspace.run(workspace, [@missing])

          assert [_] = containers(sandbox)
          assert {:ok, %Info{phase: :quiescence_unknown}} = Workspace.info(workspace)

          assert {:error, %Error{code: :quiescence_unknown}} =
                   Workspace.write(workspace, @path, @report)

          assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)
          sandbox
        after
          File.rm!(hold)
        end
      end)

    assert containers(sandbox) == []
  end

  defp check_allowlist(provider) do
    put_profile(provider, ["cat"])

    with_workspace(fn workspace ->
      assert :ok = Workspace.write(workspace, @path, @report)
      assert {:ok, @report} = ReadWithApprovedTool.read(workspace, "cat", @path)

      for tool <- ["pwd", "sh", "/bin/cat", @missing] do
        assert {:error,
                %Error{code: :policy_denied, operation: :run, details: %{action: :execute}}} =
                 ReadWithApprovedTool.read(workspace, tool, @path)
      end

      assert {:ok,
              %{
                status: :halted,
                results: [:ok],
                failure: %{
                  index: 2,
                  result: %Error{code: :policy_denied, operation: :run}
                }
              }} =
               Workspace.batch(workspace, [
                 {:write, "draft.txt", "Draft"},
                 {:run, ["pwd"], []},
                 {:write, "unreached.txt", "Unreached"}
               ])

      assert {:ok, "Draft"} = Workspace.read(workspace, "draft.txt")
      assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "unreached.txt")
    end)
  end

  defp put_profile(provider, tools) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    profile = profiles |> Map.fetch!(provider) |> Map.put(:tools, tools)
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, :review, profile))
  end

  defp hold_removal(root) do
    real_docker = System.find_executable("docker")
    assert is_binary(real_docker)
    bin = Path.join(root, "bin")
    File.mkdir_p!(Path.join(bin, "real"))
    :ok = File.ln_s(real_docker, Path.join([bin, "real", "docker"]))
    hold = Path.join(bin, "hold-removal")
    File.touch!(hold)
    shim = Path.join(bin, "docker")

    File.write!(shim, """
    #!/bin/sh
    dir=${0%/*}
    if [ "$3" = rm ] && [ -f "$dir/hold-removal" ]; then
      exit 1
    fi
    exec "$dir/real/docker" "$@"
    """)

    File.chmod!(shim, 0o700)
    path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)
    hold
  end

  defp with_workspace(fun) do
    assert {:ok, workspace} = Workspace.open(profile: :review)

    try do
      fun.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end
end
