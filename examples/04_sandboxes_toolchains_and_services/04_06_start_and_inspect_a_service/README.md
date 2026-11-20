# 04.06 Start and inspect a service

Run a TCP service over the workspace tree. Wait for its readiness
greeting, read a report, and open a second connection to the same
service. Stop the command and wait for Docker to confirm cleanup.
Save the tree after the command stops.

## Configure an approved port

Use a local Docker engine with `alpine:3.20` installed. The image
provides the example server and the `/usr/bin/nc` connector.
The host selects the connector and the TCP ports before opening the
workspace.

```elixir
config :jido_workspace,
  profiles: %{
    report_service: %{
      provider: :docker,
      image: "alpine:3.20",
      policy: :full_access,
      tools: ["/bin/sh"],
      service: %{ports: [8080], connector: "/usr/bin/nc"},
      require: %{isolation: :container, network: :disabled},
      store: "reports"
    }
  },
  stores: %{"reports" => "/var/lib/my_app/workspace"}
```

The connector is a trusted executable from the image. It takes an IPv4
address and a port number as arguments and transfers bytes between TCP
and its standard streams. Docker runs it inside the service container.
The container keeps the `none` network driver and has no published host
ports. Workspace supplies the loopback address and checks the port
against the profile. [Docker none network driver](https://docs.docker.com/engine/network/drivers/none)

## Start, connect, and stop

Copy [service.sh](service.sh) to `site/service.sh` with
`Workspace.write/3`. Write a one-line report to `site/report.txt`.
Run the script from that directory. This run waits for the service to
stop, so put it in a task.

```elixir
alias Jido.Workspace

{:ok, workspace} = Workspace.open(profile: :report_service)
:ok = Workspace.mkdir(workspace, "site")

script =
  File.read!(
    "examples/04_sandboxes_toolchains_and_services/04_06_start_and_inspect_a_service/service.sh"
  )

:ok = Workspace.write(workspace, "site/service.sh", script)
:ok = Workspace.write(workspace, "site/report.txt", "reviewed report\n")

service =
  Task.async(fn ->
    Workspace.run(workspace, ["/bin/sh", "service.sh", "8080"],
      cwd: "site",
      timeout_ms: 60_000
    )
  end)
```

Read `Workspace.info(workspace)` until it reports an active execution ID.
The same reply lists `:service_ports` under `:capabilities`. Use this ID
for connection, cancellation, and command output.

```elixir
{:ok, connection} = Workspace.connect(workspace, id, 8080)
```

An open Erlang port means that the host started the connector. Wait
for the service to send `"ready\n"` before sending `"report\n"` with
`Port.command(connection, "report\n", [:nosuspend])`. The client
receives `{connection, {:data, bytes}}` messages. Read until the newline.
During startup, retry `:service_not_ready` or a connector exit within a
bounded wait. The integration test shows the complete retry and receive
loop. Set a time and byte limit for replies in your client. The command
output limit applies to the run's output, and the connection carries
its own byte stream.

Send `"quit\n"`, read `"bye\n"`, then close the Erlang port. A second
`Workspace.connect/3` call opens a new TCP connection under the same
execution ID. Closing a client port lets the service keep running.
`Workspace.cancel/2` or `Workspace.close/1` requests a stop for the
service command and its connections.

```elixir
:ok = Workspace.cancel(workspace, id)
{:ok, %{status: :cancelled}} = Task.await(service, 5_000)
{:ok, snapshot} = Workspace.save(workspace)
:ok = Workspace.close(workspace)
```

Writes and saves return `:busy` while the service runs. If Docker
cannot confirm that the service stopped,
the run reports `:quiescence_unknown` and Workspace keeps the tree
blocked for writes and saves. Close the workspace to confirm cleanup.
A snapshot keeps the report files. Open a workspace from that reference
to read them after the service and its connections end.

## Run the integration tests

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/04_sandboxes_toolchains_and_services/04_06_start_and_inspect_a_service/example_test.exs \
  --include integration
```

The Docker tests read the report over two connections, refuse an
unapproved port, inspect the network configuration, and confirm
container removal on cancel and close. They also save the report
after cancellation and reopen it on memory. The memory test checks
that profiles with service ports require Docker.
[Integration tests](example_test.exs)
