# Workspace Sandbox

The Sandbox boundary owns execution environments and retained services.
It uses Elixir and OTP inside the `jido_workspace` package.

The Local backend runs separate OS processes under the current user. It does
not provide OS security isolation. Use trusted code with Local. The Docker
backend runs commands in containers. gVisor uses Docker with the `runsc` runtime.

Workspace policy applies to file changes and execution. See [Policy](README.md#policy).

## Use

```elixir
{:ok, sandbox} = Jido.Workspace.Sandbox.open()

:ok = Jido.Workspace.Sandbox.write(sandbox, "input.txt", "hello")
{:ok, result} = Jido.Workspace.Sandbox.exec(sandbox, "/bin/cat", ["input.txt"])
result.output
# "hello"

{:ok, service} = Jido.Workspace.Sandbox.start_service(sandbox, %{
  kind: :beam,
  args: ["+S", "2"]
})

{:ok, os_pid} = Jido.Workspace.Sandbox.call(sandbox, service, :os, :getpid, [])
:ok = Jido.Workspace.Sandbox.close(sandbox)
{:ok, sandbox} = Jido.Workspace.Sandbox.attach(sandbox.id)
:ok = Jido.Workspace.Sandbox.stop_service(sandbox, service)
:ok = Jido.Workspace.Sandbox.destroy(sandbox)
```

An external service uses `kind: :exec`, `executable`, and an `args` list.
Optional fields are `dir`, `env`, `timeout` in milliseconds, and `output_limit`
in bytes. Paths are relative to the owned root. No shell is added implicitly.
Use an explicit shell executable if a command needs shell syntax.

`exec/4` returns service status, exit status, combined output, OS PID, and an
output truncation flag. A timeout returns `status: :timed_out` and exit status
124. The default command limit is ten seconds and 64 KiB of output.
The OS PID can be `nil` if the process exits before the controller reads it.
Its output and exit status are still collected.

## Docker and gVisor

```elixir
alias Jido.Workspace.Sandbox
alias Jido.Workspace.Sandbox.Backends.Docker

# Pull or build the image before open. The API never pulls an image.
{:ok, box} = Sandbox.open(backend: {Docker, [image: "alpine:latest"]})
try do
  :ok = Sandbox.write(box, "input", "hello")
  {:ok, %{output: "hello", exit_status: 0}} = Sandbox.exec(box, "/bin/cat", ["input"])
  %{cancellation: :container, network: :disabled} = Sandbox.capabilities(box)
after
  :ok = Sandbox.destroy(box)
end

# Requires runsc registered on the engine. No automatic fallback.
{:ok, box} = Sandbox.open(provider: :gvisor, image: "alpine:latest")
:ok = Sandbox.destroy(box)
```

`provider: :docker` is a shorthand for the Docker backend with `runtime: "runc"`.
`provider: :gvisor` selects `runtime: "runsc"`. The backend tuple accepts only
`image` and `runtime`. Existing Local calls also accept `backend: {Backends.Local, []}`.

Docker requires a local Unix-socket engine. The engine endpoint is fixed at open
for execution and cleanup. An image is resolved to its immutable
ID at open. Each command or retained service gets a separate container with the
owned root at `/workspace`. Files in this directory persist across commands.
Image-layer state does not persist. File views cover the owned root, not the
image. Executables and arguments refer to container paths. The OS PID is `nil`.

The container has disabled network access, a read-only root filesystem, temporary
`/tmp`, no Linux capabilities, and no privilege escalation. Limits are one CPU,
256 MiB of memory, and 256 processes. Commands run with the controller user's
numeric UID and GID. The image entrypoint and health check are disabled. Images
with declared volumes are refused. Roots with commas, quotes, or newlines are
refused. Environment entries go to the container, not to the Docker client.
Do not mount the Docker socket or add arbitrary Docker flags through command data.

Docker supports `kind: :exec`. BEAM services and calls return
`{:error, {:unsupported_capability, :beam_call}}`. It has no checkpoints,
tunnels, stdin, PTY, or separate output streams. Capabilities come from the
controller even if a public handle is changed.

`start_service` returns after container creation. Container start can still fail.
`service_status` and `exec` return an error for an OCI start failure; its container
is removed. A command's nonzero exit code is an execution result. Exited service
containers remain until destroy for inspection. Stop and timeout remove the
whole container, including descendants. `destroy` and controller shutdown remove
all containers with the exact Sandbox ownership label and any anonymous volumes.
No images, networks, or named volumes are created by this backend. Cleanup errors
are returned. A lost engine connection can leave resources; retry destroy when
the engine is available. Controller shutdown leaves the owned root as with Local.

The backend behaviour is in `lib/jido_workspace/sandbox/backend.ex`. The controller
owns file access, policy, file views, output buffers, and status. The backend owns
service creation, exit verification, cancellation, and resource cleanup. See
[API_SPEC.md](API_SPEC.md#first-backend-increment-local-docker-and-gvisor).

## Ownership

- `open/1` creates a new owned directory. An existing directory is refused.
- `close/1` releases the caller's use of a handle. It leaves resources intact.
- `attach/1` obtains a handle within the same controller VM.
- `stop_service/2` stops one service.
- `destroy/1` stops owned services and removes the owned directory.

The application supervisor owns sandbox controllers. Services survive the exit
of the caller that created them. They do not survive controller VM shutdown.
Controller shutdown stops services; it leaves directories for inspection.

An explicit stop returns `status: :stopped`. Late OS exit messages do not change
that status or a timeout result. Stopping a service that has already exited,
timed out, or stopped leaves its result intact.

The Local BEAM connection uses OTP `peer` over standard input and output. It does not
open an Erlang distribution port. BEAM output goes to the controller's console.
External service output is retained in bounded buffers.

File operations refuse parent traversal and symlink traversal. Local processes
still have the current user's filesystem and network permissions. These path
checks do not turn the local provider into a security sandbox.

The Local POSIX provider uses `/bin/sh` and `/bin/kill`. External service stop and
timeout use SIGKILL on the direct child. They do not guarantee cleanup of
descendant processes. Services must remain in the foreground. Graceful stop,
process groups, remote providers, leases, checkpoints, and tunnels are later work.

## Tests

Use Elixir 1.18 or later and a compatible Erlang/OTP release.

```sh
mix test
mix test.integration
mix format --check-formatted
mix compile --warnings-as-errors
```

Integration examples are in `test/examples/` and have the `:integration` tag.
The alias runs each file in a separate BEAM instance. They check caller exit,
detach and attach, BEAM calls, output limits, command failure, timeouts, and cleanup.

Live Docker tests use an installed Alpine image. The test run fails if the
engine or image is unavailable. Without the flag, these tests are marked skipped.

```sh
# Optional preparation if this image is not installed:
docker pull alpine:latest
JIDO_SANDBOX_DOCKER=1 mix test.integration
# Run the same tests on a Linux engine with registered runsc:
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_RUNTIME=runsc mix test.integration
```

`JIDO_SANDBOX_IMAGE` selects another installed image with Alpine-compatible
commands. Tests use unique ownership labels, remove their containers and roots,
and check that no owned containers remain. They use the real Docker engine,
Jido Actions, and AgentServer Signals. If `runsc` is absent, they check its
refusal path. This does not count as live gVisor execution evidence.

## File access and command revisions

Target file operations use `read`, `write`, `mkdir`, `read_link`, `replace_link`,
and `verify_files` through the Sandbox controller. The controller supplies the
root. A modified handle cannot select a different root for those operations.
`location` returns canonical target identity and the provider-relative path.

Use `file_view(sandbox, relative)` to observe a command directory. Pass the view
as `files:` to `exec` or in a service specification. A stale view is refused
before process creation. A successful service status includes its input `files`
view. See [Command file views](README.md#command-file-views) for the limits.
