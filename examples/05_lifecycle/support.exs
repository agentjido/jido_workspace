defmodule Jido.Workspace.Examples.LifecycleSupport do
  @moduledoc false

  import ExUnit.Assertions
  alias Jido.Workspace.Sandbox

  def configure(root) do
    configure(:profiles, %{
      memory: %{provider: :memory, policy: :full_access, store: "reports"},
      docker: %{
        provider: :docker,
        policy: :full_access,
        store: "reports",
        image: System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest"),
        require: %{isolation: :container, network: :disabled}
      }
    })

    configure(:stores, %{"reports" => root})
  end

  defp configure(key, value) do
    previous = Application.fetch_env(:jido_workspace, key)
    Application.put_env(:jido_workspace, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_workspace, key, value)
        :error -> Application.delete_env(:jido_workspace, key)
      end
    end)
  end

  # The tests inspect the provider only to inject faults or confirm resource release.
  def provider(%{lifetime: {:profile, {controller, _release}}}, kind) do
    assert %{provider: {^kind, provider}} = :sys.get_state(controller)
    {controller, provider}
  end

  def containers(sandbox, filters \\ []) do
    label = "label=dev.jido.workspace.sandbox=" <> sandbox.id
    {ids, 0} = docker(["ps", "--all", "--quiet", "--filter", label] ++ filters)
    String.split(ids)
  end

  def container_running(sandbox) do
    case containers(sandbox, ["--filter", "status=running"]) do
      [id] -> id
      [] -> nil
    end
  end

  def clean_up_docker_on_failure(sandbox) do
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(sandbox.pid), do: Sandbox.destroy(sandbox)

      case containers(sandbox) do
        [] -> :ok
        ids -> docker(["rm", "--force", "--volumes"] ++ ids)
      end

      File.rm_rf!(sandbox.root)
    end)
  end

  def docker(args), do: System.cmd("docker", args, stderr_to_stdout: true)

  def await(fun, description, timeout \\ 2_000) do
    await_result(fun, description, System.monotonic_time(:millisecond) + timeout)
  end

  defp await_result(fun, description, deadline) do
    case fun.() do
      result when result in [false, nil] ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk(description)

        Process.sleep(10)
        await_result(fun, description, deadline)

      result ->
        result
    end
  end
end
