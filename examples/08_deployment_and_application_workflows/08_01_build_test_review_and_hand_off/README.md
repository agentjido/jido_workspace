# 08.01 Build, test, review, and hand off

Build a report in one working tree. Follow the build and test output.
Save only after both commands exit successfully. Give a separate reader
the saved reference after the builder closes.

## Configure the host

Use the same snapshot store for both builders and the reviewer. The
reviewer can import and read. The builders can edit, run tools, and save.
Start IEx from the repository root with a temporary store directory.

```sh
export WORKSPACE_RESULTS_DIR=$(mktemp -d)
iex -S mix
```

```elixir
root = System.fetch_env!("WORKSPACE_RESULTS_DIR")
Application.put_env(:jido_workspace, :stores, %{"reports" => root})
policy = [:read, :write, :execute, :save]

Application.put_env(:jido_workspace, :profiles, %{
  lua_build: %{provider: :memory, policy: policy, tools: ["lua"], store: "reports"},
  docker_build: %{
    provider: :docker,
    policy: policy,
    tools: ["sh"],
    image: "alpine:3.20",
    require: %{isolation: :container, network: :disabled},
    store: "reports"
  },
  reviewer: %{provider: :memory, policy: :read_only, store: "reports"}
})
```

The memory profile uses embedded Lua and mediated file access. The Docker
profile uses a trusted script in a local Alpine image with the container
network disabled. The script runs `tr` and `cmp` inside the container.

## Run the build and test

Run this code from the repository root. To repeat it on Docker, use
`{:docker_build, "sh", "report.sh"}` for the profile, tool, and script.
The host keeps the build handle private while the helper runs and saves.

```elixir
alias Jido.Workspace

fixture = "examples/08_deployment_and_application_workflows/08_01_build_test_review_and_hand_off"
Code.require_file(Path.join(fixture, "example.ex"))
alias Jido.Workspace.Examples.BuildAndReview

{profile, tool, script} = {:lua_build, "lua", "report.lua"}
opts = [cwd: "app", output_limit: 4_096]
build = {[tool, script, "build", "draft; Q4.txt", "report.txt"], opts}
test = {[tool, script, "test", "expected.txt", "report.txt"], opts}

on_output = fn stage, _id, slice ->
  if slice.dropped_bytes > 0 do
    IO.puts("#{stage} skipped #{slice.dropped_bytes} output bytes")
  end

  IO.binwrite(slice.bytes)
end

{:ok, workspace} = Workspace.open(profile: profile)

snapshot =
  try do
    :ok = Workspace.mkdir(workspace, "app")
    :ok = Workspace.write(workspace, "app/" <> script, File.read!(Path.join(fixture, script)))
    :ok = Workspace.write(workspace, "app/draft; Q4.txt", "quarterly report\n")
    :ok = Workspace.write(workspace, "app/expected.txt", "REPORT\nQUARTERLY REPORT\n")
    {:ok, snapshot} = BuildAndReview.run(workspace, build, test, on_output)
    snapshot
  after
    :ok = Workspace.close(workspace)
  end
```

Each stage sets `notify_start: {reader_pid, reference}` on
`Workspace.run/3`. The reader uses the execution ID in the start message
to read the output by byte offset. It finishes reading each stage before
the next command replaces the output record. It uses the run result to
check the exit status. An admission error can return before a start
message, so the helper also sends the run result to the reader.
[Live output](../../02_commands/02_02_stream_live_output/README.md)

If a test fails, `BuildAndReview.run/4` returns the stage and its reason.
A built file can remain in the working tree. Correct the input and rerun
while the handle is open. The failed run gives the reviewer no new
reference. An earlier snapshot remains readable.

## Hand off the saved result

Send the JSON reference to a reader that has access to the host store.
This task opens its own read-only handle to the checked tree.

```elixir
reference = Jason.encode!(snapshot)

review = Task.async(fn ->
  {:ok, workspace} = Workspace.open(profile: :reviewer, from: Jason.decode!(reference))

  try do
    {:ok, report} = Workspace.read(workspace, "app/report.txt")
    report
  after
    :ok = Workspace.close(workspace)
  end
end)

"REPORT\nQUARTERLY REPORT\n" = Task.await(review)
```

## Run the integration tests

```sh
mix test examples/08_deployment_and_application_workflows/08_01_build_test_review_and_hand_off/example_test.exs \
  --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/08_deployment_and_application_workflows/08_01_build_test_review_and_hand_off/example_test.exs \
  --include integration
```

The tests verify successful builds, failed tests, and corrected retries
on memory and Docker. The Docker command waits for input after it emits
test output. The host reads that output and confirms that save is busy
before it releases the command. A separate reader then opens the saved
version and confirms that its profile denies writes and saves.
[Integration tests](example_test.exs)
