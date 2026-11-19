Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.NativeReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Jido.Workspace.Examples.NativeReport
  alias Jido.Workspace.Sandbox
  alias Jido.Workspace.Sandbox.Backends.Docker

  @tag :tmp_dir
  test "the native program and file API share one directory on the trusted local runner", ctx do
    exercise([provider: :local], ctx.tmp_dir)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to prove the isolated native path"
  end

  @tag :tmp_dir
  test "the same native workflow runs in an isolated container", ctx do
    image = System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest")
    runtime = System.get_env("JIDO_SANDBOX_RUNTIME", "runc")

    assert %{network: :disabled, cancellation: :container, runtime: ^runtime} =
             exercise([backend: {Docker, [image: image, runtime: runtime]}], ctx.tmp_dir)
  end

  defp exercise(options, temporary_directory) do
    root = Path.join(temporary_directory, "sandbox")
    assert {:ok, sandbox} = Sandbox.open([root: root] ++ options)

    capabilities =
      try do
        assert {:ok, "Report for today\n"} = NativeReport.run(sandbox, "Report for today\n")

        assert :ok = Sandbox.close(sandbox)
        assert {:ok, _attached} = Sandbox.attach(sandbox.id)
        assert File.dir?(root)
        Sandbox.capabilities(sandbox)
      after
        assert :ok = Sandbox.destroy(sandbox)
      end

    refute File.exists?(root)
    assert {:error, :not_found} = Sandbox.attach(sandbox.id)
    capabilities
  end
end
