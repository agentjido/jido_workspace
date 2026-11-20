Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.TransferFilesTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Entry, Error, Execution}
  alias Jido.Workspace.Examples.TransferFiles

  import Jido.Workspace.Examples.LifecycleSupport,
    only: [await: 2, configure: 1, containers: 1, docker: 1, provider: 2]

  @source "files/source.bin"
  @target "files/copy.bin"
  @original "Previous file\n"
  @block_size 262_144

  setup %{tmp_dir: root}, do: configure(Path.join(root, "snapshots"))

  test "memory streams large files and rolls back interrupted writes" do
    check_transfer(:memory)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to run the transfer tests on Docker"
  end

  test "Docker streams the same files and rolls back interrupted writes" do
    check_transfer(:docker)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check staging cleanup in a checkout"
  end

  test "close and controller loss remove a staged file and keep the host checkout", %{
    tmp_dir: root
  } do
    checkout = Path.join(root, "checkout")
    File.mkdir!(checkout)
    File.mkdir!(Path.join(checkout, "files"))
    File.write!(Path.join(checkout, @target), @original)
    put_profile(:checkout, :docker, %{checkout: checkout})

    for interruption <- [:close, :controller_loss] do
      assert {:ok, workspace} = Workspace.open(profile: :checkout)
      {pid, ref, barrier} = start_paused_write(workspace)
      assert File.read!(Path.join(checkout, @target)) == @original
      assert length(File.ls!(Path.join(checkout, "files"))) == 2

      interrupt(workspace, interruption)
      send(pid, {:continue, barrier})
      assert_receive {^pid, {:error, %Error{code: :closed}}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert File.read!(Path.join(checkout, @target)) == @original
      assert File.ls!(Path.join(checkout, "files")) == ["copy.bin"]
    end

    with_workspace(:checkout, [], fn workspace ->
      assert :ok = Workspace.write_stream(workspace, @target, ["Retried\n"])
    end)

    assert File.read!(Path.join(checkout, @target)) == "Retried\n"
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to test loss of the sandbox that owns the staging file"
  end

  test "loss of the native staging owner keeps write access blocked", %{tmp_dir: root} do
    checkout = Path.join(root, "checkout")
    File.mkdir_p!(Path.join(checkout, "files"))
    File.write!(Path.join(checkout, @target), @original)
    put_profile(:checkout, :docker, %{checkout: checkout})

    assert {:ok, workspace} = Workspace.open(profile: :checkout)
    {_, sandbox} = provider(workspace, :native)

    on_exit(fn ->
      case containers(sandbox) do
        [] -> :ok
        ids -> assert {_, 0} = docker(["rm", "--force", "--volumes"] ++ ids)
      end
    end)

    {pid, ref, barrier} = start_paused_write(workspace)
    sandbox_monitor = Process.monitor(sandbox.pid)
    Process.exit(sandbox.pid, :kill)
    assert_receive {:DOWN, ^sandbox_monitor, :process, _, :killed}

    send(pid, {:continue, barrier})
    assert_receive {^pid, {:error, %Error{code: :quiescence_unknown}}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)
    assert {:error, %Error{code: :cleanup_unconfirmed}} = Workspace.close(workspace)
    assert {:error, %Error{code: :checkout_busy}} = Workspace.open(profile: :checkout)
    assert File.read!(Path.join(checkout, @target)) == @original

    assert [".jido-write-" <> _staging, "copy.bin"] =
             Enum.sort(File.ls!(Path.join(checkout, "files")))
  end

  defp check_transfer(profile) do
    snapshot =
      with_workspace(profile, [], fn workspace ->
        assert {:error, %Error{code: :not_found}} =
                 Workspace.write_stream(workspace, @source, ["No parent"])

        assert :ok = Workspace.mkdir(workspace, "files")
        {size, hash} = check_copy(workspace)
        assert :ok = Workspace.write(workspace, @target, @original)
        check_interrupted_writes(workspace)
        assert {:ok, snapshot} = Workspace.save(workspace)
        {snapshot, size, hash}
      end)

    check_profile_limits(profile, snapshot)
  end

  defp check_copy(workspace) do
    block = :binary.copy(<<0, 255, 42, 1>>, div(@block_size, 4))
    chunks = Stream.map(1..9, fn number -> [block, <<number>>] end)
    size = 9 * (@block_size + 1)
    hash = :crypto.hash(:sha256, Enum.to_list(chunks))

    assert :ok = Workspace.write_stream(workspace, @source, chunks)
    assert :ok = TransferFiles.copy(workspace, @source, @target)
    assert {:ok, ^size, ^hash} = TransferFiles.checksum(workspace, @target)

    assert {:ok, <<42, 1, 1, 0, 255>>} =
             Workspace.read_chunk(workspace, @target, @block_size - 2, 5)

    assert {:ok, <<9>>} = Workspace.read_chunk(workspace, @target, size - 1, 20)
    assert {:ok, ""} = Workspace.read_chunk(workspace, @target, size, 1)
    assert {:ok, ""} = Workspace.read_chunk(workspace, @target, size + 9, 1)

    assert {:error, %Error{code: :invalid_input}} =
             Workspace.read_chunk(workspace, @target, 0, 1_048_577)

    assert {:ok, %Execution{exit_status: 0}} =
             Workspace.run(workspace, ["cat", @target], output_limit: 0)

    tiny_chunks = Stream.map(1..2_050, fn index -> <<rem(index, 251)>> end)
    assert :ok = Workspace.write_stream(workspace, @target, Stream.concat([""], tiny_chunks))
    assert {:ok, bytes} = Workspace.read_chunk(workspace, @target, 0, 4_096)
    assert bytes == tiny_chunks |> Enum.to_list() |> IO.iodata_to_binary()

    {size, hash}
  end

  defp check_interrupted_writes(workspace) do
    failed_source =
      Stream.concat(["Partial data"], Stream.map([:fail], fn _ -> raise "Source failed" end))

    assert {:error, %Error{code: :stream_failed}} =
             Workspace.write_stream(workspace, @target, failed_source)

    assert {:error, %Error{code: :stream_failed}} =
             Workspace.write_stream(workspace, "files/missing.bin", failed_source)

    assert {:error, %Error{code: :not_found}} =
             Workspace.read_chunk(workspace, "files/missing.bin", 0, 1)

    assert {:error, %Error{code: :invalid_input}} =
             Workspace.write_stream(workspace, @target, ["Partial data", {:invalid}])

    {pid, ref, _} = start_paused_write(workspace)
    assert {:ok, %{phase: :writing}} = Workspace.info(workspace)
    assert {:ok, @original} = Workspace.read_chunk(workspace, @target, 0, 65_536)
    assert {:error, %Error{code: :busy}} = Workspace.save(workspace)
    assert {:error, %Error{code: :busy}} = Workspace.write(workspace, @target, "Blocked")

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    await(
      fn -> match?({:ok, %{phase: :ready}}, Workspace.info(workspace)) end,
      "The controller did not discard the staged file"
    )

    assert {:ok, @original} = Workspace.read(workspace, @target)

    assert {:ok, [%Entry{path: @target}, %Entry{path: @source}]} =
             Workspace.list(workspace, "files")
  end

  defp check_profile_limits(profile, {snapshot, size, hash}) do
    put_profile(:limited, profile, %{limits: %{write_stream_bytes: 5}})
    put_profile(:reader, profile, %{policy: :read_only})

    with_workspace(:limited, [from: snapshot], fn workspace ->
      assert {:error, %Error{code: :transfer_limit}} =
               Workspace.write_stream(workspace, @target, ["123", "456"])

      assert {:ok, @original} = Workspace.read(workspace, @target)
      assert {:ok, ^size, ^hash} = TransferFiles.checksum(workspace, @source)
      assert :ok = Workspace.write_stream(workspace, @target, ["12", "345"])
      assert {:ok, "12345"} = Workspace.read_chunk(workspace, @target, 0, 8)

      assert {:error, %Error{code: :transfer_limit}} =
               Workspace.write_stream(workspace, @target, [:binary.copy("X", 1_048_577)])

      assert {:ok, "12345"} = Workspace.read(workspace, @target)
      assert :ok = Workspace.write_stream(workspace, @target, [])
      assert {:ok, ""} = Workspace.read_chunk(workspace, @target, 0, 1)
    end)

    with_workspace(:reader, [from: snapshot], fn workspace ->
      chunks = Stream.map([:attempt], fn _ -> flunk("A denied upload read its source") end)

      assert {:error, %Error{code: :policy_denied}} =
               Workspace.write_stream(workspace, @target, chunks)

      assert {:ok, @original} = Workspace.read_chunk(workspace, @target, 0, 65_536)
    end)
  end

  defp start_paused_write(workspace) do
    parent = self()
    barrier = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        rest =
          Stream.map([:last], fn _ ->
            send(parent, {self(), :staged})

            receive do
              {:continue, ^barrier} -> "Last part"
            end
          end)

        result = Workspace.write_stream(workspace, @target, Stream.concat(["First part"], rest))
        send(parent, {self(), result})
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {^pid, :staged}, 5_000
    {pid, monitor, barrier}
  end

  defp interrupt(workspace, :close), do: assert(:ok = Workspace.close(workspace))

  defp interrupt(workspace, :controller_loss) do
    {controller, sandbox} = provider(workspace, :native)
    ref = Process.monitor(sandbox.pid)
    Process.exit(controller, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 10_000
  end

  defp with_workspace(profile, opts, fun) do
    assert {:ok, workspace} = Workspace.open([profile: profile] ++ opts)

    try do
      fun.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp put_profile(name, provider, options) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    profile = Map.merge(Map.fetch!(profiles, provider), options)
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, name, profile))
  end
end
