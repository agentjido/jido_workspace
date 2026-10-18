defmodule Jido.Workspace.Deploy.Test.NodeApp do
  @moduledoc false
  alias Jido.Workspace.Deploy.{Artifact, Recipe, Snapshot}

  def artifact(version, opts \\ []) do
    server = """
    const http = require('node:http');
    let count = 0;
    const server = http.createServer((req, res) => {
      if (req.url === '/add') count += #{version};
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({version: #{version}, count}));
    });
    server.listen(Number(process.argv[2]), '127.0.0.1');
    """

    verify =
      if Keyword.get(opts, :bad_verify, false) do
        "process.exit(7);"
      else
        """
        (async () => {
          for (let n = 0; n < 100; n++) {
            try {
              const data = await (await fetch('http://127.0.0.1:' + process.argv[2])).json();
              if (data.version === #{version}) { console.log(JSON.stringify(data)); return; }
            } catch (_) {}
            await new Promise(resolve => setTimeout(resolve, 20));
          }
          process.exit(1);
        })();
        """
      end

    {:ok, snapshot} =
      Snapshot.new(
        %{
          "server.js" => %{bytes: server, mode: 0o644},
          "verify.js" => %{bytes: verify, mode: 0o644}
        },
        id: "node-source-#{version}"
      )

    {:ok, artifact} = Artifact.new(:source, Integer.to_string(version), snapshot)
    artifact
  end

  def recipe(port) do
    %Recipe{
      prepare: [{"node", ["--check", "server.js"]}],
      service: %{executable: "node", args: ["server.js", Integer.to_string(port)]},
      verify: {"node", ["verify.js", Integer.to_string(port)]}
    }
  end

  def port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  def get(port, path \\ "/") do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.0\r\nHost: localhost\r\n\r\n")
    response = receive_all(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, bytes} -> receive_all(socket, acc <> bytes)
      {:error, :closed} -> acc
    end
  end
end
