# 03.05 Scope credentials and diagnostics

The host supplies a fixture credential to one running command. It
selects the executable and Docker image, and keeps the workspace handle
in trusted code.

Put a trusted executable at `bin/verify` in a dedicated host-owned
checkout. The example mounts that checkout at `/workspace`. Register a
snapshot store named `"reports"` and add this profile to the host
configuration. [Profile and commands](example.ex)

```elixir
%{
  credential: %{
    provider: :docker,
    checkout: checkout,
    image: "alpine:3.20",
    store: "reports",
    policy: [:read, :execute, :save],
    tools: ["/workspace/bin/verify"],
    require: %{isolation: :container, network: :disabled, stdin: :pipe},
    limits: %{output_limit: 0}
  }
}
```

Start the approved command in another process with
`Workspace.run(workspace, ["/workspace/bin/verify"], stdin: :pipe)`.
Use the execution ID from the command start event to send input from
the host. [Observe command events](../../05_lifecycle/05_04_inspect_state/README.md)

```elixir
Workspace.input(workspace, execution_id, fixture_credential <> "\n")
```

Retry the input call on `:input_not_ready` or `:input_busy`. A
successful call means the pipe accepted the bytes. Check the command
result to see if the verifier accepted the input. An ID from a previous
command returns `:execution_not_active`.

The Docker profile mounts the checkout read-only and disables
networking and container logging. With a zero-byte output limit, live
and final results retain no command output bytes. They can still report
the number of bytes dropped, truncation, exit status, and duration.
Workspace removes raw input and port output from formatted OTP status
reports. Raw VM tracing and debug buffers can expose the credential.
The host controls access to VM debugging and the Docker daemon.
The tool allowlist checks the command entry point. The program controls
how it handles its input and what it passes to child processes.

## Test the boundary

The fixture program checks the input, writes it to standard output and
standard error, and tries to write it into the checkout. The test
checks live and final output, command events, input errors, formatted
OTP status, and the container configuration. It confirms that the
attempted file write fails and that saving and reopening the snapshot
preserves the original tree. The memory provider refuses a profile
that requires a command input pipe. [Integration tests](example_test.exs)

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/03_security_and_policy/03_05_scope_credentials_and_diagnostics/example_test.exs \
  --include integration
```

Use a local Docker engine and the installed Alpine image. Run the same
test command without the Docker environment variables to check the memory
requirement alone.
