# 03.04 Control network access

Require disabled networking in the host profile. The same profile can
still run a command that reads a file from its workspace.

```elixir
alias Jido.Workspace

Application.put_env(:jido_workspace, :profiles, %{
  offline: %{
    provider: :docker,
    image: "alpine:3.20",
    policy: [:read, :write, :execute],
    require: %{isolation: :container, network: :disabled}
  }
})

{:ok, workspace} = Workspace.open(profile: :offline)
:ok = Workspace.write(workspace, "report.txt", "Local report")
{:ok, %{exit_status: 0, output: "Local report"}} =
  Workspace.run(workspace, ["cat", "report.txt"])
:ok = Workspace.close(workspace)
```

Workspace checks the network requirement at open. The Docker provider
uses the `none` network driver for each command. This gives the container
its own loopback interface and keeps it off other networks. Memory
meets the requirement through its virtual tools. A memory profile
refuses the native HTTP client before execution. [Docker none driver](https://docs.docker.com/engine/network/drivers/none/)

## Test a live endpoint

The test starts a private HTTP endpoint on a temporary internal Docker
bridge. It uses the image that Workspace selected. A control container
on that bridge receives the fixture bytes before and after the
Workspace request. The probe runs the same request inside Workspace.
It exits with a nonzero status, and inspection
confirms that Docker used network mode `none`. The workspace can still
edit and save its tree. [NetworkProbe](example.ex)

The test uses a numeric IPv4 address and disables proxy use in the
HTTP client. The bridge and its containers are local test resources.
The fixture publishes zero host ports and the test removes the bridge
and containers on exit.

```sh
mix test examples/03_security_and_policy/03_04_control_network_access/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/03_security_and_policy/03_04_control_network_access/example_test.exs \
  --include integration
```

The live test needs a local Docker engine with permission to create a
temporary bridge and an installed image with the BusyBox `wget` and
`nc` applets. It checks the private IPv4 endpoint on Docker.
[Integration tests](example_test.exs)
