# Jido Agent Integration

`Jido.VFS` supplies storage adapters in `jido_workspace`. A host
application can use these adapters from a library, Shell session, or Jido
Action. This guide describes how to write the Action wrappers in the host.

## Recommendation

Keep Jido and its Action definitions in the host application. The host
decides which adapters, users, and operations to expose.

## Better pattern

Use `Jido.VFS` for files and expose agent tools in one of these forms:

- Thin action modules in the consuming app.
- A separate `jido_vfs_actions` package.
- A tool pack in a separately maintained ecosystem integration package.

## Suggested default action set

Safe-by-default read actions:

- `ReadFile`
- `ReadStream`
- `ListContents`
- `Stat`
- `FileExists`
- `GetVisibility`
- `ListRevisions`
- `ReadRevision`

Opt-in mutation actions:

- `WriteFile`
- `WriteStream`
- `DeleteFile`
- `MoveFile`
- `CopyFile`
- `CopyBetweenFilesystems`
- `CreateDirectory`
- `DeleteDirectory`
- `SetVisibility`
- `Commit`
- `Rollback`
- `Clear`

## Recommended policy boundary

For autonomous agents, split actions into at least two tool groups:

- Read-only filesystem inspection tools.
- Mutating filesystem tools that are explicitly enabled by the host application.

This mirrors how other Jido packages separate safe browsing/status operations from state-changing operations.

## Action context shape

The cleanest integration point is to pass a configured filesystem through action context:

```elixir
%{
  filesystem: Jido.VFS.Adapter.Local.configure(prefix: "/workspace")
}
```

Alternative patterns that also work:

- Resolve a named filesystem module that uses `Jido.VFS.Filesystem`.
- Look up the adapter/config from application config for multi-tenant agents.

The consuming application declares consolidated Jido as its dependency.
Keep the Action wrapper in that application. VFS has no required Jido dependency.

## Example action wrapper

```elixir
defmodule MyApp.Actions.ReadFile do
  use Jido.Action,
    name: "read_file",
    description: "Read a file from the configured virtual filesystem",
    schema: Jido.Joi.object(%{path: Jido.Joi.string()})

  @impl true
  def run(params, %{filesystem: filesystem}) do
    case Jido.VFS.read(filesystem, params.path) do
      {:ok, contents} -> {:ok, %{path: params.path, contents: contents}}
      {:error, error} -> {:error, error}
    end
  end
end
```

## Keep tool ownership in the host

Test the wrappers with the same permissions and filesystem configuration
that the host provides to the agent.
