Code.require_file("../../05_lifecycle/support.exs", __DIR__)

defmodule Jido.Workspace.Examples.ServiceTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  import Jido.Workspace.Examples.LifecycleSupport

  @port 8080
  @report "reviewed report\n"
  @profile %{ports: [@port], connector: "/usr/bin/nc"}
  @wait 4_000

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))
    profiles = Application.fetch_env!(:jido_workspace, :profiles)

    Application.put_env(
      :jido_workspace,
      :profiles,
      Map.merge(profiles, %{
        service: Map.merge(profiles.docker, %{tools: ["/bin/sh"], service: @profile}),
        memory_service: Map.put(profiles.memory, :service, @profile),
        invalid_connector:
          Map.put(profiles.docker, :service, %{@profile | connector: "/workspace/client"})
      })
    )

    :ok
  end

  test "a memory workspace has no service ports and profile validation refuses a writable connector" do
    assert {:error, %Error{code: :invalid_profile}} = Workspace.open(profile: :memory_service)
    assert {:error, %Error{code: :invalid_profile}} = Workspace.open(profile: :invalid_connector)
    assert {:ok, workspace} = Workspace.open(profile: :memory)

    try do
      assert {:error,
              %Error{code: :unsupported_capability, details: %{capability: :service_ports}}} =
               Workspace.connect(workspace, "execution-unused", @port)

      assert {:ok, %Execution{exit_status: 0}} = Workspace.run(workspace, ["echo", "ok"])
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to test a live loopback service"
  end

  test "a Docker service accepts reconnects on an approved port and stops before save" do
    with_service(fn workspace, sandbox, run, id ->
      assert {:ok, %{capabilities: %{network: :disabled, service_ports: [@port]}}} =
               Workspace.info(workspace)

      assert {:error, %Error{code: :policy_denied, details: %{action: :connect}}} =
               Workspace.connect(workspace, id, @port + 1)

      assert {:error, %Error{code: :invalid_input}} = Workspace.connect(workspace, id, 0)

      assert {:error, %Error{code: :execution_not_active}} =
               Workspace.connect(workspace, "execution-unused", @port)

      first = connect(workspace, id)
      assert {:ok, @report} = exchange(first, "report\n")
      assert {:ok, "bye\n"} = exchange(first, "quit\n")
      if Port.info(first), do: Port.close(first)

      second = connect(workspace, id)
      assert second != first
      assert {:ok, @report} = exchange(second, "report\n")

      assert [container] = containers(sandbox)
      format = "{{.HostConfig.NetworkMode}} {{len .HostConfig.PortBindings}}"
      assert {"none 0\n", 0} = docker(["inspect", "--format", format, container])

      assert {:error, %Error{code: :busy}} = Workspace.save(workspace)
      assert {:error, %Error{code: :busy}} = Workspace.write(workspace, "review", "pending")
      assert :ok = Workspace.cancel(workspace, id)
      assert {:ok, %Execution{id: ^id, status: :cancelled}} = Task.await(run, @wait)
      assert_receive {^second, {:exit_status, _}}, @wait
      assert containers(sandbox) == []

      assert {:error, %Error{code: :execution_not_active}} =
               Workspace.connect(workspace, id, @port)

      assert {:ok, snapshot} = Workspace.save(workspace)
      assert {:ok, restored} = Workspace.open(profile: :memory, from: snapshot)

      try do
        assert {:ok, @report} = Workspace.read(restored, "site/report.txt")
      after
        assert :ok = Workspace.close(restored)
      end
    end)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to test a live loopback service"
  end

  test "closing a workspace stops the service and its open connection" do
    with_service(fn workspace, sandbox, run, id ->
      connection = connect(workspace, id)
      assert {:ok, @report} = exchange(connection, "report\n")

      assert :ok = Workspace.close(workspace, timeout_ms: @wait)
      assert {:ok, %Execution{id: ^id, status: :cancelled}} = Task.await(run, @wait)
      assert_receive {^connection, {:exit_status, _}}, @wait
      assert containers(sandbox) == []
      refute File.exists?(sandbox.root)
    end)
  end

  defp with_service(fun) do
    assert {:ok, workspace} = Workspace.open(profile: :service)
    {_, sandbox} = provider(workspace, :native)
    clean_up_docker_on_failure(sandbox)

    try do
      assert :ok = Workspace.mkdir(workspace, "site")

      assert :ok =
               Workspace.write(
                 workspace,
                 "site/service.sh",
                 File.read!(Path.join(__DIR__, "service.sh"))
               )

      assert :ok = Workspace.write(workspace, "site/report.txt", @report)

      run =
        Task.async(fn ->
          Workspace.run(workspace, ["/bin/sh", "service.sh", Integer.to_string(@port)],
            cwd: "site",
            timeout_ms: 20_000
          )
        end)

      id =
        await(
          fn ->
            {:ok, %{active_execution_id: id}} = Workspace.info(workspace)
            id
          end,
          "Workspace did not admit the service",
          @wait
        )

      fun.(workspace, sandbox, run, id)
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp connect(workspace, id) do
    await(
      fn ->
        case Workspace.connect(workspace, id, @port) do
          {:ok, connection} ->
            case line(connection, "", System.monotonic_time(:millisecond) + 1_000) do
              {:ok, "ready\n"} ->
                connection

              {:error, :exited} ->
                nil

              {:error, :timeout} ->
                if Port.info(connection), do: Port.close(connection)
                nil
            end

          {:error, %Error{code: :service_not_ready}} ->
            nil
        end
      end,
      "Service did not send its readiness greeting",
      @wait
    )
  end

  defp exchange(connection, request) do
    assert Port.command(connection, request, [:nosuspend])
    line(connection, "", System.monotonic_time(:millisecond) + @wait)
  end

  defp line(_, buffer, _) when byte_size(buffer) > 1024, do: {:error, :reply_limit}

  defp line(port, buffer, deadline) do
    if String.ends_with?(buffer, "\n") do
      {:ok, buffer}
    else
      receive do
        {^port, {:data, bytes}} -> line(port, buffer <> bytes, deadline)
        {^port, {:exit_status, _}} -> {:error, :exited}
      after
        max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :timeout}
      end
    end
  end
end
