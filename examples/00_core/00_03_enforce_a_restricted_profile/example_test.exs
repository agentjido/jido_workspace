Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.RestrictedReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.VFS.Adapter
  alias Jido.Workspace
  alias Jido.Workspace.Examples.RestrictedReport
  alias Jido.Workspace.Sandbox
  alias Jido.Workspace.Sandbox.Backends.Docker

  test "a read-only Workspace permits reads and refuses writes and commands", %{tmp_dir: root} do
    path = Path.join(root, "report.txt")
    File.write!(path, "Approved report")

    assert {:ok, workspace} =
             Workspace.open(
               policy: :read_only,
               adapter: Adapter.Local,
               adapter_opts: [prefix: root]
             )

    try do
      assert %{
               read: {:ok, "Approved report"},
               write: {:error, %Workspace.Error{code: :policy_denied}},
               run: {:error, %Workspace.Error{code: :policy_denied}}
             } = RestrictedReport.workspace(workspace)

      assert File.read!(path) == "Approved report"
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  test "invalid policy or provider selection refuses creation", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "refused")
    assert {:error, %Workspace.Error{code: :invalid_input}} = Workspace.open(policy: :unknown)
    assert {:error, :invalid_policy} = Sandbox.open(policy: :unknown, root: root)
    assert {:error, :unsupported_provider} = Sandbox.open(provider: :unknown, root: root)
    refute File.exists?(root)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check policy and isolation on Docker"
  end

  test "a restricted Sandbox refuses execution and writes before starting a service", ctx do
    root = Path.join(ctx.tmp_dir, "restricted")
    assert {:ok, sandbox} = Sandbox.open(root: root, policy: :read_only, backend: docker())

    try do
      # The host stages the input. The read-only caller uses only the Sandbox API.
      File.write!(Path.join(root, "report.txt"), "Approved report")

      assert %{
               read: {:ok, "Approved report"},
               write: {:error, {:policy_denied, :write}},
               run: {:error, {:policy_denied, :execute}}
             } = RestrictedReport.sandbox(sandbox)

      assert {:ok, %{services: services}} = Sandbox.info(sandbox)
      assert services == %{}
      assert {:ok, "Approved report"} = Sandbox.read(sandbox, "report.txt")
    after
      assert :ok = Sandbox.destroy(sandbox)
    end
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check filesystem isolation"
  end

  test "native commands can read the owned root but cannot read a sibling fixture", ctx do
    root = Path.join(ctx.tmp_dir, "sandbox")
    outside = Path.join(ctx.tmp_dir, "outside.txt")
    File.write!(outside, "Outside fixture")
    assert {:ok, sandbox} = Sandbox.open(root: root, backend: docker())

    try do
      :ok = Sandbox.write(sandbox, "report.txt", "Inside fixture")

      assert {:ok, %{exit_status: 0, output: "Inside fixture"}} =
               Sandbox.exec(sandbox, "/bin/cat", ["report.txt"])

      assert {:ok, %{exit_status: 1, output: output}} =
               Sandbox.exec(sandbox, "/bin/cat", [outside])

      refute output =~ "Outside fixture"
    after
      assert :ok = Sandbox.destroy(sandbox)
    end
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check failed Docker allocation"
  end

  test "an unavailable Docker image leaves no owned directory", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "missing-image")
    {Docker, options} = docker()
    name = "jido-workspace-example-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    assert {:error, {:image_unavailable, _}} =
             Sandbox.open(root: root, backend: {Docker, Keyword.put(options, :image, name)})

    refute File.exists?(root)
  end

  defp docker do
    {Docker,
     [
       image: System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest"),
       runtime: System.get_env("JIDO_SANDBOX_RUNTIME", "runc")
     ]}
  end
end
