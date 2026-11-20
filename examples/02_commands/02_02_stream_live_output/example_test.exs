Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.FollowOutputTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.FollowOutput
  import Jido.Workspace.Examples.LifecycleSupport

  setup %{tmp_dir: root}, do: configure(root)

  test "memory streams before exit and reports a gap after an observer waits" do
    assert {:ok, workspace} = Workspace.open(profile: :memory)

    task =
      Task.async(fn ->
        Workspace.run(workspace, ["sleep", "30"], timeout_ms: 20_000, output_limit: 4)
      end)

    id = running_id(workspace)

    first =
      await(
        fn ->
          case Workspace.output(workspace, id) do
            {:ok, %{bytes: "...\n", done?: false} = slice} -> slice
            _ -> nil
          end
        end,
        "The running virtual command did not emit bytes"
      )

    assert first.dropped_bytes == first.next_offset - 4

    later =
      await(
        fn ->
          case Workspace.output(workspace, id, first.next_offset) do
            {:ok, %{dropped_bytes: dropped, done?: false} = slice} when dropped > 0 -> slice
            _ -> nil
          end
        end,
        "The observer did not fall behind",
        4_000
      )

    assert byte_size(later.bytes) == 4
    assert later.next_offset == first.next_offset + later.dropped_bytes + 4
    assert :ok = Workspace.cancel(workspace, id)

    assert {:ok, %Execution{id: ^id, status: :cancelled, output: "Slee", truncated: true}} =
             Task.await(task)

    assert {:ok, %{done?: true, next_offset: last}} =
             Workspace.output(workspace, id, later.next_offset)

    assert last >= later.next_offset
    assert :ok = Workspace.close(workspace)
    assert {:error, %Error{code: :closed}} = Workspace.output(workspace, id)
  end

  test "a zero-byte limit reports a gap and a new command replaces the record" do
    assert {:ok, workspace} = Workspace.open(profile: :memory)

    assert {:ok, %Execution{id: id, output: "", truncated: true}} =
             Workspace.run(workspace, ["echo", "abc"], output_limit: 0)

    assert {:ok, %{bytes: "", next_offset: 4, dropped_bytes: 4, done?: true}} =
             Workspace.output(workspace, id)

    assert {:ok, %Execution{id: next_id}} = Workspace.run(workspace, ["echo", "next"])
    assert {:error, %Error{code: :output_unavailable}} = Workspace.output(workspace, id)
    assert {:ok, %{bytes: "next\n", done?: true}} = Workspace.output(workspace, next_id)
    assert :ok = Workspace.close(workspace)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check live Docker output"
  end

  test "Docker observers can read independently, detect a gap, and drain the final bytes" do
    assert {:ok, workspace} = Workspace.open(profile: :docker)
    {_controller, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)

    script = """
    mkfifo /tmp/advance /tmp/finish
    printf abcd
    read -r line </tmp/advance
    printf efghijklmnop
    read -r line </tmp/finish
    printf qr
    """

    task =
      Task.async(fn ->
        Workspace.run(workspace, ["sh", "-c", script], timeout_ms: 20_000, output_limit: 4)
      end)

    id = running_id(workspace)
    container = await(fn -> container_running(sandbox) end, "No running container", 10_000)
    wait_for_offset(workspace, id, 4)
    first = %{bytes: "abcd", next_offset: 4, dropped_bytes: 0, done?: false}
    assert [^first] = workspace |> FollowOutput.follow(id) |> Enum.take(1)
    assert {:ok, ^first} = Workspace.output(workspace, id)
    assert {:error, %Error{code: :invalid_input}} = Workspace.output(workspace, id, 5)

    assert {_, 0} = docker(["exec", container, "sh", "-c", ~S(printf 'go\n' >/tmp/advance)])
    wait_for_offset(workspace, id, 16)

    assert {:ok, %{bytes: "mnop", next_offset: 16, dropped_bytes: 8, done?: false}} =
             Workspace.output(workspace, id, 4)

    assert {:ok, %{bytes: "mnop", next_offset: 16, dropped_bytes: 12, done?: false}} =
             Workspace.output(workspace, id)

    assert {:ok, %{bytes: "", next_offset: 16, dropped_bytes: 0, done?: false}} =
             Workspace.output(workspace, id, 16)

    # The main process can exit and stop the exec helper as it releases the pipe.
    assert {_, status} = docker(["exec", container, "sh", "-c", ~S(printf 'go\n' >/tmp/finish)])
    assert status in [0, 137]

    assert {:ok, %Execution{id: ^id, status: :exited, output: "abcd", truncated: true}} =
             Task.await(task, 10_000)

    last = %{bytes: "qr", next_offset: 18, dropped_bytes: 0, done?: true}
    assert [^last] = workspace |> FollowOutput.follow(id, 16) |> Enum.to_list()
    assert :ok = Workspace.close(workspace)
  end

  defp running_id(workspace) do
    await(
      fn ->
        case Workspace.info(workspace) do
          {:ok, %{phase: :running, active_execution_id: id}} -> id
          _ -> nil
        end
      end,
      "The command did not start"
    )
  end

  defp wait_for_offset(workspace, id, offset) do
    await(
      fn ->
        match?({:ok, %{next_offset: ^offset, done?: false}}, Workspace.output(workspace, id))
      end,
      "The running command did not reach byte offset #{offset}",
      5_000
    )
  end
end
