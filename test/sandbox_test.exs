defmodule Jido.Workspace.SandboxTest do
  use ExUnit.Case, async: true
  alias Jido.Workspace.Sandbox

  test "owned roots, relative paths, and provider capabilities are explicit" do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    assert Sandbox.capabilities(sandbox).isolation == :process
    assert {:error, :unsupported_provider} = Sandbox.open(provider: :unknown)
    assert {:error, {:root, :eexist}} = Sandbox.open(root: sandbox.root)
    assert {:error, :invalid_path} = Sandbox.path(sandbox, "../outside")
    assert {:error, :invalid_path} = Sandbox.path(sandbox, "/outside")
    assert :ok = Sandbox.write(sandbox, "nested/test.txt", "hello")
    assert File.read!(Path.join(sandbox.root, "nested/test.txt")) == "hello"
    File.ln_s!(System.tmp_dir!(), Path.join(sandbox.root, "escape"))
    assert {:error, :symlink_path} = Sandbox.write(sandbox, "escape/test.txt", "bad")
    assert :ok = Sandbox.close(sandbox)
    assert {:ok, attached} = Sandbox.attach(sandbox.id)
    assert attached.pid == sandbox.pid
  end

  test "destroy removes the owned root and registration" do
    {:ok, sandbox} = Sandbox.open()
    assert :ok = Sandbox.destroy(sandbox)
    refute File.exists?(sandbox.root)
    assert {:error, :not_found} = Sandbox.attach(sandbox.id)
  end

  test "the Local backend contract preserves existing calls" do
    alias Jido.Workspace.Sandbox.Backends.Local
    {:ok, sandbox} = Sandbox.open(backend: {Local, []})
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    assert %{provider: :local, cancellation: :direct_child} = Sandbox.capabilities(sandbox)

    assert {:ok, %{output: "backend", exit_status: 0}} =
             Sandbox.exec(sandbox, "/bin/sh", ["-c", "printf backend"])

    assert {:ok, attached} = Sandbox.attach(sandbox.id)
    assert attached == sandbox
  end

  test "invalid backend options fail without retaining an owned root" do
    alias Jido.Workspace.Sandbox.Backends.{Docker, Local}

    root =
      Path.join(System.tmp_dir!(), "jido-invalid-backend-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    for backend <- [
          {Local, [unknown: true]},
          {Docker, []},
          {Docker, [image: "alpine:latest", privileged: true]},
          {Docker, [:invalid]}
        ] do
      assert {:error, :invalid_backend_options} = Sandbox.open(backend: backend, root: root)
      refute File.exists?(root)
    end

    assert {:error, :unsupported_provider} = Sandbox.open(backend: {Local, []}, provider: :local)
    assert {:error, :unsupported_provider} = Sandbox.open(backend: {String, []})
  end
end
