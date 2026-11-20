Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.EmbeddedRuntimeTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  import Jido.Workspace.Examples.LifecycleSupport

  @program Path.join(__DIR__, "report.lua")
  @draft "draft; Q4.txt"
  @report "QUARTERLY REPORT\n"
  @loop ~S"""
  workspace.write("pending.txt", "staged before stop")
  print("ready")
  while true do end
  """

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))
    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    lua = Map.merge(profiles.memory, %{tools: ["lua"], require: %{isolation: :mediated}})
    read_only = %{lua | policy: [:read, :execute, :import]}

    Application.put_env(
      :jido_workspace,
      :profiles,
      Map.merge(profiles, %{lua: lua, read_only_lua: read_only})
    )

    :ok
  end

  test "a Lua script shares the working directory and produces the same report as Python" do
    snapshot =
      in_workspace([profile: :lua], fn workspace ->
        assert {:ok, %{capabilities: %{isolation: :mediated, network: :disabled}}} =
                 Workspace.info(workspace)

        assert :ok = Workspace.mkdir(workspace, "build")
        assert :ok = Workspace.write(workspace, "build/report.lua", File.read!(@program))
        assert :ok = Workspace.write(workspace, "build/" <> @draft, "quarterly report\n")

        assert {:ok, %Execution{status: :exited, exit_status: 0, output: "Lua 5.3\n"}} =
                 Workspace.run(workspace, ["lua", "report.lua", @draft, "report.txt"],
                   cwd: "build"
                 )

        assert {:ok, @report} = Workspace.read(workspace, "build/report.txt")
        assert {:ok, snapshot} = Workspace.save(workspace)
        snapshot
      end)

    in_workspace([profile: :memory, from: snapshot], fn workspace ->
      assert {:ok, @report} = Workspace.read(workspace, "build/report.txt")

      assert {:error, %Error{code: :policy_denied}} =
               Workspace.run(workspace, ["lua", "report.lua"])
    end)

    in_workspace([profile: :read_only_lua, from: snapshot], fn workspace ->
      assert {:error, %Error{code: :policy_denied}} =
               Workspace.run(workspace, ["lua", "report.lua"], cwd: "build")
    end)
  end

  test "the VM has mediated files and refuses host I/O and traversal", %{tmp_dir: root} do
    fixture = Path.expand(Path.join(root, "outside.txt"))
    File.write!(fixture, "outside")

    script = ~S"""
    assert(io == nil and os == nil and package == nil and debug == nil)
    assert(not pcall(loadfile, arg[1]))
    assert(not pcall(require, "os"))
    assert(not pcall(workspace.read, arg[1]))
    assert(not pcall(workspace.read, "../outside.txt"))
    assert(not pcall(workspace.write, "../outside.txt", "overwrite"))
    workspace.write("inside.txt", "inside")
    assert(workspace.read("inside.txt") == "inside")
    """

    in_workspace([profile: :lua], fn workspace ->
      assert :ok = Workspace.write(workspace, "check.lua", script)

      assert {:ok, %Execution{status: :exited, exit_status: 0}} =
               Workspace.run(workspace, ["lua", "check.lua", fixture])

      assert {:ok, "inside"} = Workspace.read(workspace, "inside.txt")
      assert File.read!(fixture) == "outside"
    end)
  end

  test "cancel stops a busy loop and discards its staged changes" do
    in_workspace([profile: :lua], fn workspace ->
      assert :ok = Workspace.write(workspace, "loop.lua", @loop)

      task =
        Task.async(fn -> Workspace.run(workspace, ["lua", "loop.lua"], timeout_ms: 5_000) end)

      id =
        await(
          fn ->
            with {:ok, %{active_execution_id: id}} when is_binary(id) <- Workspace.info(workspace),
                 {:ok, %{bytes: "ready\n", done?: false}} <- Workspace.output(workspace, id) do
              id
            else
              _ -> nil
            end
          end,
          "The Lua script did not reach its loop"
        )

      assert {:error, %Error{code: :busy}} = Workspace.save(workspace)
      assert {:error, %Error{code: :busy}} = Workspace.read(workspace, "pending.txt")
      assert :ok = Workspace.cancel(workspace, id)

      assert {:ok, %Execution{id: ^id, status: :cancelled, exit_status: nil, output: "ready\n"}} =
               Task.await(task)

      assert_ready(workspace)
    end)
  end

  test "deadline stops a busy loop and retains its bounded output" do
    in_workspace([profile: :lua], fn workspace ->
      assert :ok = Workspace.write(workspace, "loop.lua", @loop)

      assert {:ok,
              %Execution{
                id: id,
                status: :timed_out,
                exit_status: nil,
                output: "rea",
                truncated: true
              }} =
               Workspace.run(workspace, ["lua", "loop.lua"], timeout_ms: 1_000, output_limit: 3)

      assert {:ok, %{bytes: "dy\n", dropped_bytes: 3, done?: true}} =
               Workspace.output(workspace, id)

      assert_ready(workspace)
    end)
  end

  test "script errors and invalid publish targets leave all staged files unchanged" do
    in_workspace([profile: :lua], fn workspace ->
      assert :ok = Workspace.mkdir(workspace, "z-directory")
      assert :ok = Workspace.write(workspace, "a.txt", "original")

      for suffix <- [~S[error("script failed")], ~S[workspace.write("z-directory", "invalid")]] do
        script = ~S[workspace.write("a.txt", "changed")] <> "\n" <> suffix
        assert :ok = Workspace.write(workspace, "fail.lua", script)

        assert {:ok, %Execution{status: :exited, exit_status: 1, output: output}} =
                 Workspace.run(workspace, ["lua", "fail.lua"])

        assert output != ""
        assert {:ok, "original"} = Workspace.read(workspace, "a.txt")
      end

      assert {:error, %Error{code: :start_failed}} =
               Workspace.run(workspace, ["lua", "absent.lua"])

      assert_ready(workspace)
    end)
  end

  test "the total draft byte limit fails evaluation without publishing any file" do
    script = ~S"""
    local block = string.rep("x", 600000)
    workspace.write("first.txt", block)
    workspace.write("second.txt", block)
    """

    in_workspace([profile: :lua], fn workspace ->
      assert :ok = Workspace.write(workspace, "limit.lua", script)

      assert {:ok, %Execution{exit_status: 1, output: output}} =
               Workspace.run(workspace, ["lua", "limit.lua"])

      assert output =~ "draft limit"
      assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "first.txt")
      assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "second.txt")
    end)
  end

  defp assert_ready(workspace) do
    assert {:ok, %{phase: :ready}} = Workspace.info(workspace)
    assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "pending.txt")
    assert :ok = Workspace.write(workspace, "review.txt", "reviewed")
    assert {:ok, %{kind: "snapshot"}} = Workspace.save(workspace)
  end

  defp in_workspace(opts, fun) do
    assert {:ok, workspace} = Workspace.open(opts)

    try do
      fun.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end
end
