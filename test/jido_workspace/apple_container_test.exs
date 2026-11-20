defmodule Jido.Workspace.AppleContainerTest do
  use ExUnit.Case, async: false

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Sandbox}
  alias Jido.Workspace.Sandbox.Backends.AppleContainer

  @moduletag :tmp_dir
  @host {{:unix, :darwin}, "aarch64-apple-darwin", {26, 0, 0}}
  @image "localhost/jido-apple-fault:fixture"
  @digest "sha256:" <> String.duplicate("a", 64)

  test "rejects unsupported hosts before looking up the CLI" do
    for host <- [
          {{:unix, :linux}, "aarch64-linux", {26, 0, 0}},
          {{:unix, :darwin}, "x86_64-apple-darwin", {26, 0, 0}},
          {{:unix, :darwin}, "aarch64-apple-darwin", {15, 7, 0}}
        ] do
      assert {:error, {:backend_unavailable, :apple_container, :unsupported_host}} =
               AppleContainer.prepare([image: @image], host, fn _ -> flunk("looked up CLI") end)
    end
  end

  test "reports a missing CLI, stopped service, or missing local image", %{tmp_dir: dir} do
    assert {:error, {:backend_unavailable, :apple_container, :cli_not_found}} =
             AppleContainer.prepare([image: @image], @host, fn "container" -> nil end)

    cli = install_fake(dir)
    File.touch!(Path.join(dir, "stopped"))

    assert {:error, {:backend_unavailable, :apple_container, :service_unavailable}} =
             AppleContainer.prepare([image: @image], @host, fn _ -> cli end)

    File.rm!(Path.join(dir, "stopped"))

    assert {:error, {:image_unavailable, "missing:fixture"}} =
             AppleContainer.prepare([image: "missing:fixture"], @host, fn _ -> cli end)

    refute File.exists?(Path.join(dir, "owned-resource"))
  end

  test "public sandbox open leaves the root untouched when Apple is unavailable", %{tmp_dir: dir} do
    old_path = System.get_env("PATH")
    System.put_env("PATH", dir)
    on_exit(fn -> restore_path(old_path) end)
    root = Path.join(dir, "root")

    assert {:error, {:backend_unavailable, :apple_container, cause}} =
             Sandbox.open(provider: :apple_container, image: @image, root: root)

    assert cause in [:cli_not_found, :unsupported_host]
    refute File.exists?(root)

    put_config(:profiles, %{
      apple_fault: %{provider: :apple_container, image: @image, policy: :full_access}
    })

    assert {:error, %Error{code: :backend_unavailable}} = Workspace.open(profile: :apple_fault)
  end

  test "an attached exit and a delete reply wait for exact all-container absence", %{
    tmp_dir: dir
  } do
    sandbox = open_fault_sandbox(dir)
    File.touch!(Path.join(dir, "delay-once"))

    assert {:ok, %{status: :exited, exit_status: 7, output: "command output\n", container: id}} =
             Sandbox.exec(sandbox, "/bin/echo", [])

    # The first delete claimed success while the ID still appeared in the list.
    # Later lists contain a different ID with the same prefix.
    assert File.read!(Path.join(dir, "deletions")) == "#{id}\n#{id}\n"
    assert :ok = Sandbox.write(sandbox, "next.txt", "safe")
    assert :ok = Sandbox.destroy(sandbox)
  end

  test "an unconfirmed create stays fenced until that ID can be removed", %{tmp_dir: dir} do
    sandbox = open_fault_sandbox(dir)
    File.touch!(Path.join(dir, "lose-create"))

    assert {:error, :quiescence_unknown} = Sandbox.exec(sandbox, "/bin/echo", [])
    assert {:error, :quiescence_unknown} = Sandbox.write(sandbox, "next.txt", "blocked")
    assert File.dir?(sandbox.root)

    # The server sees an empty list while the create outcome is still unknown.
    # Make the resource visible and retry cleanup with the original ID.
    File.rename!(Path.join(dir, "late-resource"), Path.join(dir, "owned-resource"))
    assert :ok = Sandbox.destroy(sandbox)
    refute File.exists?(sandbox.root)
  end

  test "Workspace blocks writes and saves when removal cannot be confirmed", %{tmp_dir: dir} do
    cli = install_fake(dir)

    case AppleContainer.prepare([image: @image], native_host(), fn _ -> cli end) do
      {:error, {:backend_unavailable, :apple_container, :unsupported_host}} ->
        # Run the same fault through the sandbox controller on other hosts.
        sandbox = open_fault_sandbox(dir)
        File.touch!(Path.join(dir, "list-fails"))
        assert {:error, :quiescence_unknown} = Sandbox.exec(sandbox, "/bin/echo", [])
        assert {:error, :quiescence_unknown} = Sandbox.write(sandbox, "next.txt", "blocked")
        File.rm!(Path.join(dir, "list-fails"))
        assert :ok = Sandbox.destroy(sandbox)

      {:ok, _} ->
        check_public_fence(dir)
    end
  end

  defp check_public_fence(dir) do
    old_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> old_path)
    on_exit(fn -> restore_path(old_path) end)

    put_config(:profiles, %{
      apple_fault: %{
        provider: :apple_container,
        image: @image,
        policy: :full_access,
        store: "test"
      }
    })

    put_config(:stores, %{"test" => Path.join(dir, "snapshots")})
    assert {:ok, workspace} = Workspace.open(profile: :apple_fault)
    on_exit(fn -> Workspace.close(workspace) end)

    File.touch!(Path.join(dir, "list-fails"))
    assert {:error, %Error{code: :quiescence_unknown}} = Workspace.run(workspace, ["/bin/echo"])

    assert {:error, %Error{code: :quiescence_unknown}} =
             Workspace.write(workspace, "x", "blocked")

    assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)
    root = File.read!(Path.join(dir, "mount-source"))

    assert {:error, %Error{code: :cleanup_unconfirmed}} =
             Workspace.close(workspace, timeout_ms: 100)

    assert File.dir?(root)
    File.rm!(Path.join(dir, "list-fails"))
    assert :ok = Workspace.close(workspace)
    refute File.exists?(root)
  end

  defp native_host,
    do: {:os.type(), List.to_string(:erlang.system_info(:system_architecture)), :os.version()}

  defp open_fault_sandbox(dir) do
    cli = install_fake(dir)
    assert {:ok, opts} = AppleContainer.prepare([image: @image], @host, fn _ -> cli end)
    id = "apple-fault-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(dir, "sandbox")

    assert {:ok, pid} =
             DynamicSupervisor.start_child(Jido.Workspace.Sandbox.Supervisor, {
               Sandbox.Server,
               {id, {:owned, root}, :full_access, AppleContainer, opts, self()}
             })

    %Sandbox{id: id, pid: pid, root: root, provider: :apple_container}
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)

  defp put_config(key, value) do
    old = Application.fetch_env(:jido_workspace, key)
    Application.put_env(:jido_workspace, key, value)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:jido_workspace, key, value)
        :error -> Application.delete_env(:jido_workspace, key)
      end
    end)
  end

  defp install_fake(dir) do
    image = %{
      configuration: %{name: @image, descriptor: %{digest: @digest}},
      variants: [%{platform: %{architecture: "arm64", os: "linux"}}]
    }

    File.write!(Path.join(dir, "image.json"), Jason.encode!([image]))
    cli = Path.join(dir, "container")

    File.write!(cli, """
    #!/bin/sh
    set -eu
    cd "$(/usr/bin/dirname "$0")"
    case "$1" in
      system)
        [ ! -f stopped ] || exit 1
        printf '%s' '{"status":"running","client":{"version":"1.7.1"},"server":{"version":"1.7.1"}}'
        ;;
      image)
        [ "$3" = '#{@image}' ] || exit 1
        /bin/cat image.json
        ;;
      create)
        id=$3
        shift 3
        while [ "$1" != --mount ]; do shift; done
        mount=${2#*source=}
        printf '%s' "${mount%,target=*}" > mount-source
        if [ -f lose-create ]; then
          printf '%s' "$id" > late-resource
          exit 1
        fi
        printf '%s' "$id" > owned-resource
        printf '%s\\n' "$id"
        ;;
      inspect)
        [ "$2" = "$(/bin/cat owned-resource)" ] || exit 1
        printf '[{"id":"%s","configuration":{"image":{"descriptor":{"digest":"#{@digest}"}},' "$2"
        printf '%s' '"initProcess":{"executable":"/bin/echo","workingDirectory":"/workspace","arguments":[]},'
        printf '"mounts":[{"source":"%s","destination":"/workspace","options":[],"type":{"virtiofs":{}}}],' "$(/bin/cat mount-source)"
        printf '%s' '"networks":[],"publishedPorts":[],"publishedSockets":[],"dns":null,"ssh":false,"readOnly":true,"capDrop":["ALL"],"runtimeHandler":"container-runtime-linux"}}]'
        ;;
      start)
        [ "$3" = "$(/bin/cat owned-resource)" ] || exit 1
        printf 'command output\\n'
        exit 7
        ;;
      delete)
        [ "$2" = --force ] && [ "$3" = "$(/bin/cat owned-resource 2>/dev/null)" ] || exit 1
        printf '%s\\n' "$3" >> deletions
        if [ -f delay-once ]; then
          /bin/rm delay-once
        else
          /bin/rm owned-resource
        fi
        printf '%s\\n' "$3"
        ;;
      list)
        [ "$2 $3" = '--all --quiet' ] && [ ! -f list-fails ] || exit 1
        if [ -f owned-resource ]; then printf '%s\\n' "$(/bin/cat owned-resource)"; fi
        if [ -f deletions ]; then printf '%s-other\\n' "$(/usr/bin/tail -n 1 deletions)"; fi
        ;;
      *) exit 1 ;;
    esac
    """)

    File.chmod!(cli, 0o755)
    cli
  end
end
