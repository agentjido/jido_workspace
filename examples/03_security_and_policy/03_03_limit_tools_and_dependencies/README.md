# 03.03 Limit tools and dependencies

Set `tools:` on the host profile to list the exact command names a
caller can start. Use the same report workflow on memory and Docker.

```elixir
alias Jido.Workspace

Application.put_env(:jido_workspace, :profiles, %{
  review_memory: %{provider: :memory, policy: :full_access, tools: ["cat"]},
  review_docker: %{
    provider: :docker,
    policy: :full_access,
    image: "alpine:3.20",
    tools: ["cat"]
  }
})

{:ok, workspace} = Workspace.open(profile: :review_memory)
:ok = Workspace.write(workspace, "report.txt", "Approved report\n")
{:ok, %{exit_status: 0, output: "Approved report\n"}} =
  Workspace.run(workspace, ["cat", "report.txt"])

{:error, %Workspace.Error{code: :policy_denied, details: %{action: :execute}}} =
  Workspace.run(workspace, ["pwd"])

:ok = Workspace.close(workspace)
```

Select `:review_docker` to use the installed image. The tests exercise both
profiles and check the same rule for a command in a batch.
[ReadWithApprovedTool](example.ex) checks the exit status and output limit
before using the returned bytes.

## Dependency results

| Situation | Public result |
| --- | --- |
| The command name differs from all names in `tools:` | Run returns `:policy_denied` before provider execution. |
| A memory profile lists a tool outside the virtual tool set | Open returns `:invalid_profile`. |
| A permitted Docker executable is missing and Docker confirms removal of the failed container | Run returns `:start_failed`. File edits and saves can continue. |
| A running command exits with a nonzero code | Run returns an execution with that exit status. |
| Workspace cannot confirm cleanup | Run returns `:quiescence_unknown`. Workspace blocks writes and saves. |

The list controls the command entry point. The tool interprets its arguments
and can start child processes where the provider permits them. The host
chooses the image and the tools to expose. Docker resolves a native executable
at launch, so a later step can use an executable an earlier step produced
when the host permits its exact name.

The Docker tests distinguish a failed launch from an actual exit with
code 127. They also simulate a failed removal, check the write fence,
then confirm that close removes the test container after removal is available.

```sh
mix test examples/03_security_and_policy/03_03_limit_tools_and_dependencies/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/03_security_and_policy/03_03_limit_tools_and_dependencies/example_test.exs \
  --include integration
```

The live Docker tests require a local engine and an installed image.
[Integration tests](example_test.exs)
