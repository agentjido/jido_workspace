defmodule Jido.Workspace.Sandbox.LifecycleTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Jido.Workspace.Sandbox

  test "BEAM services survive caller exit and handle close; destroy stops them" do
    parent = self()

    {caller, ref} =
      spawn_monitor(fn ->
        {:ok, sandbox} = Sandbox.open()
        {:ok, service} = Sandbox.start_service(sandbox, %{kind: :beam, args: ["+S", "2"]})
        send(parent, {sandbox, service})
      end)

    assert_receive {sandbox, service}, 20_000
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
    assert {:ok, os_pid} = Sandbox.call(sandbox, service, :os, :getpid, [])
    refute List.to_string(os_pid) == System.pid()
    assert :ok = Sandbox.close(sandbox)
    assert {:ok, _} = Sandbox.call(sandbox, service, :erlang, :system_info, [:version])
    assert :ok = Sandbox.destroy(sandbox)
    assert {:error, _} = Sandbox.call(sandbox, service, :os, :getpid, [])
  end

  test "execution reports exit status, bounded output, timeout, and explicit stop" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)

    assert {:ok, %{exit_status: 7, output: "failure"}} =
             Sandbox.exec(sandbox, "/bin/sh", ["-c", "printf failure; exit 7"])

    assert {:ok, %{output: "1234", truncated: true}} =
             Sandbox.exec(sandbox, "/bin/sh", ["-c", "printf 12345678"], output_limit: 4)

    assert {:ok, %{status: :timed_out, exit_status: 124}} =
             Sandbox.exec(sandbox, "/bin/sleep", ["5"], timeout: 50)

    assert {:ok, service} =
             Sandbox.start_service(sandbox, %{kind: :exec, executable: "/bin/sleep", args: ["5"]})

    assert :ok = Sandbox.stop_service(sandbox, service)
    assert {:ok, %{status: :stopped}} = Sandbox.service_status(sandbox, service)
  end

  test "short processes retain their output and exit status" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)

    for _ <- 1..50 do
      assert {:ok, %{status: :exited, exit_status: 0, output: ""}} =
               Sandbox.exec(sandbox, "/bin/sh", ["-c", "exit 0"])

      assert {:ok, %{status: :exited, exit_status: 7, output: "outerr"}} =
               Sandbox.exec(sandbox, "/bin/sh", ["-c", "printf out; printf err >&2; exit 7"])
    end
  end

  test "late exit messages do not change an explicit stop" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)

    {:ok, id} =
      Sandbox.start_service(sandbox, %{kind: :exec, executable: "/bin/sleep", args: ["5"]})

    {:ok, %{services: services}} = Sandbox.info(sandbox)
    port = services[id].handle

    assert :ok = Sandbox.stop_service(sandbox, id)
    assert {:ok, %{status: :stopped} = stopped} = Sandbox.service_status(sandbox, id)
    # These are the messages that an OS process can send after stop returns.
    send(sandbox.pid, {port, {:exit_status, 137}})
    send(sandbox.pid, {:EXIT, port, :normal})
    assert {:ok, ^stopped} = Sandbox.service_status(sandbox, id)
    assert :ok = Sandbox.stop_service(sandbox, id)
    assert {:ok, ^stopped} = Sandbox.service_status(sandbox, id)
  end

  test "late exit messages and repeated stop preserve a timeout result" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)

    assert {:ok, %{status: :timed_out, exit_status: 124}} =
             Sandbox.exec(sandbox, "/bin/sleep", ["5"], timeout: 30)

    {:ok, %{services: services}} = Sandbox.info(sandbox)
    [{id, service}] = Map.to_list(services)
    send(sandbox.pid, {service.handle, {:exit_status, 137}})
    send(sandbox.pid, {:EXIT, service.handle, :normal})
    assert {:ok, %{status: :timed_out, exit_status: 124}} = Sandbox.service_status(sandbox, id)
    assert :ok = Sandbox.stop_service(sandbox, id)
    assert {:ok, %{status: :timed_out, exit_status: 124}} = Sandbox.service_status(sandbox, id)
  end

  test "stop preserves the result of a process that has already exited" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)

    assert {:ok, %{status: :exited, exit_status: 7}} =
             Sandbox.exec(sandbox, "/bin/sh", ["-c", "exit 7"])

    {:ok, %{services: services}} = Sandbox.info(sandbox)
    [id] = Map.keys(services)
    assert :ok = Sandbox.stop_service(sandbox, id)
    assert {:ok, %{status: :exited, exit_status: 7}} = Sandbox.service_status(sandbox, id)
  end
end
