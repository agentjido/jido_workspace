Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.NetworkProbeTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution, Sandbox}
  alias Jido.Workspace.Examples.NetworkProbe

  import Jido.Workspace.Examples.LifecycleSupport,
    only: [
      await: 3,
      clean_up_docker_on_failure: 1,
      configure: 1,
      containers: 1,
      docker: 1,
      provider: 2
    ]

  @body "Private endpoint fixture\n"
  @port 8080

  setup %{tmp_dir: root}, do: configure(Path.join(root, "snapshots"))

  test "a network-disabled memory profile runs virtual tools and refuses a native client" do
    configure_profile(:memory, %{require: %{network: :disabled}})

    with_workspace(:memory, fn workspace ->
      check_local_report(workspace)

      assert {:error, %Error{code: :policy_denied, operation: :run}} =
               NetworkProbe.request(workspace, "http://127.0.0.1:0/fixture.txt")
    end)
  end

  test "a profile request for host networking fails during validation" do
    configure_profile(:memory, %{require: %{network: :host}})

    assert {:error, %Error{code: :invalid_profile, operation: :open}} =
             Workspace.open(profile: :memory)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to test network isolation on a local engine"
  end

  test "a network-disabled Docker command cannot reach a live private endpoint" do
    with_workspace(:docker, fn workspace ->
      {_, sandbox} = provider(workspace, :native)
      clean_up_docker_on_failure(sandbox)
      assert %{image: image, network: :disabled} = Sandbox.capabilities(sandbox)
      {network, url} = start_endpoint(image)
      assert {@body, 0} = connected_request(network, image, url)

      assert {:ok, %Execution{status: :exited, exit_status: code, output: output}} =
               NetworkProbe.request(workspace, url)

      assert code > 0
      refute output =~ @body

      assert [container] = containers(sandbox)

      assert {"none\n", 0} =
               docker(["inspect", "--format", "{{.HostConfig.NetworkMode}}", container])

      check_local_report(workspace)
      assert {:ok, %{kind: "snapshot"}} = Workspace.save(workspace)
      assert {@body, 0} = connected_request(network, image, url)
    end)
  end

  defp start_endpoint(image) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    network = "jido-example-network-" <> suffix
    endpoint = "jido-example-endpoint-" <> suffix
    assert {_, 0} = docker(["network", "create", "--driver", "bridge", "--internal", network])

    on_exit(fn ->
      docker(["rm", "--force", "--volumes", endpoint, network <> "-control"])
      assert {_, 0} = docker(["network", "rm", network])
    end)

    script = ~S'''
    cat > /tmp/serve <<'SERVER'
    #!/bin/sh
    cr=$(printf '\r')
    while IFS= read -r header; do
      [ "$header" = "$cr" ] && break
    done
    printf 'HTTP/1.0 200 OK\r\nContent-Length: %s\r\n\r\n%s' "${#JIDO_NETWORK_FIXTURE_BODY}" "$JIDO_NETWORK_FIXTURE_BODY"
    SERVER
    chmod 700 /tmp/serve
    exec /bin/busybox nc -lk -p "$1" -e /tmp/serve
    '''

    assert {_, 0} =
             docker([
               "run",
               "--detach",
               "--pull",
               "never",
               "--name",
               endpoint,
               "--network",
               network,
               "--read-only",
               "--tmpfs",
               "/tmp:rw,exec,nosuid,nodev,size=1m",
               "--env",
               "JIDO_NETWORK_FIXTURE_BODY=" <> @body,
               "--entrypoint",
               "/bin/busybox",
               image,
               "sh",
               "-c",
               script,
               "endpoint",
               Integer.to_string(@port)
             ])

    await(
      fn ->
        args = NetworkProbe.argv(endpoint_url("127.0.0.1"))
        docker(["exec", endpoint] ++ args) == {@body, 0}
      end,
      "The private HTTP endpoint did not become ready",
      5_000
    )

    assert {address, 0} =
             docker([
               "inspect",
               "--format",
               "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
               endpoint
             ])

    address = String.trim(address)
    assert {:ok, _} = :inet.parse_ipv4_address(String.to_charlist(address))
    {network, endpoint_url(address)}
  end

  defp connected_request(network, image, url) do
    [tool | args] = NetworkProbe.argv(url)
    control = network <> "-control"

    assert {_, 0} =
             docker([
               "create",
               "--pull",
               "never",
               "--name",
               control,
               "--network",
               network,
               "--entrypoint",
               tool,
               image
               | args
             ])

    try do
      docker(["start", "--attach", control])
    after
      assert {_, 0} = docker(["rm", "--force", "--volumes", control])
    end
  end

  defp endpoint_url(address), do: "http://#{address}:#{@port}/fixture.txt"

  defp check_local_report(workspace) do
    assert :ok = Workspace.write(workspace, "report.txt", "Local report")

    assert {:ok, %Execution{exit_status: 0, output: "Local report"}} =
             Workspace.run(workspace, ["cat", "report.txt"])
  end

  defp configure_profile(name, attrs) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    profile = profiles |> Map.fetch!(name) |> Map.merge(attrs)
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, name, profile))
  end

  defp with_workspace(profile, fun) do
    assert {:ok, workspace} = Workspace.open(profile: profile)

    try do
      fun.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end
end
