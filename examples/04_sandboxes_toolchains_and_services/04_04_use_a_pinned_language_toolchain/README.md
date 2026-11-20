# 04.04 Use a pinned language toolchain

Run Python 3.13.18 in a disposable Docker workspace. The program reads
a draft and writes a report in the same directory. Read and save the
report with the Workspace file API. Reopen it on memory after Docker
cleanup.

## Install the image

Install the image by digest on a local Docker engine. A digest identifies
the same image release when a registry tag moves. Workspace resolves the
reference to an image ID at open and uses that ID for each command.
[Docker image digests](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier)

```sh
docker pull python@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
```

## Configure the profiles

```elixir
config :jido_workspace,
  profiles: %{
    python_report: %{
      provider: :docker,
      image: "python@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e",
      policy: :full_access,
      tools: ["python3"],
      require: %{isolation: :container, network: :disabled},
      store: "reports"
    },
    review: %{provider: :memory, policy: :full_access, store: "reports"}
  },
  stores: %{"reports" => "/var/lib/my_app/workspace"}
```

The host selects the toolchain in the profile. If the image is unavailable,
`Workspace.open/1` returns an error with code `:image_unavailable`. Install
the configured digest and retry open.

## Run and save the report

Read the [example program](report.py) from the repository root and copy it
into the live tree. Pass the draft name as one argument. Python uses the
relative working directory for both the input and the output.

```elixir
alias Jido.Workspace

program =
  File.read!(
    "examples/04_sandboxes_toolchains_and_services/04_04_use_a_pinned_language_toolchain/report.py"
  )

{:ok, workspace} = Workspace.open(profile: :python_report)

snapshot =
  try do
    :ok = Workspace.mkdir(workspace, "build")
    :ok = Workspace.write(workspace, "build/report.py", program)
    :ok = Workspace.write(workspace, "build/draft; Q4.txt", "quarterly report\n")

    {:ok, %{status: :exited, exit_status: 0, output: "Python 3.13.18\n"}} =
      Workspace.run(workspace, ["python3", "report.py", "draft; Q4.txt", "report.txt"],
        cwd: "build"
      )

    {:ok, "QUARTERLY REPORT\n"} = Workspace.read(workspace, "build/report.txt")
    {:ok, snapshot} = Workspace.save(workspace)
    snapshot
  after
    :ok = Workspace.close(workspace)
  end

{:ok, review} = Workspace.open(profile: :review, from: snapshot)

try do
  {:ok, "QUARTERLY REPORT\n"} = Workspace.read(review, "build/report.txt")
after
  :ok = Workspace.close(review)
end
```

## Test the example

```sh
JIDO_SANDBOX_DOCKER=1 mix test \
  examples/04_sandboxes_toolchains_and_services/04_04_use_a_pinned_language_toolchain/example_test.exs \
  --include integration
```

The integration test ran on Docker with Linux arm64. It checks the
actual Python version, container image ID, working directory, and network
mode. It also checks the report after close and restore to memory. The
unavailable-image test checks the open error and verifies that open leaves
no workspace directory. [Integration tests](example_test.exs)
