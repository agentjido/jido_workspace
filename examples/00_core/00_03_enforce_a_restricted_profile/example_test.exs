Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.RestrictedReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.Examples.RestrictedReport

  setup %{tmp_dir: root} do
    author = %{provider: :memory, policy: :full_access, store: "reports"}

    docker = %{
      provider: :docker,
      policy: :full_access,
      image: System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest"),
      store: "reports",
      require: %{isolation: :container, network: :disabled}
    }

    configure(:stores, %{"reports" => Path.join(root, "snapshots")})

    configure(:profiles, %{
      author: author,
      read_only_memory: %{author | policy: :read_only},
      read_only_docker: %{docker | policy: :read_only},
      docker: docker,
      incompatible: Map.put(author, :require, %{isolation: :container}),
      invalid: %{author | policy: :unknown}
    })

    :ok
  end

  test "a read-only memory profile permits reads and refuses writes and commands" do
    verify_read_only(:read_only_memory, prepare_report())
  end

  test "invalid profiles and unmet requirements refuse open" do
    assert {:error, %Workspace.Error{code: :unknown_profile}} =
             Workspace.open(profile: :missing)

    assert {:error, %Workspace.Error{code: :invalid_profile}} =
             Workspace.open(profile: :invalid)

    assert {:error, %Workspace.Error{code: :unsupported_capability}} =
             Workspace.open(profile: :incompatible)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check policy on Docker"
  end

  test "memory and Docker enforce the same read-only policy on a prepared report" do
    snapshot = prepare_report()
    verify_read_only(:read_only_memory, snapshot)
    verify_read_only(:read_only_docker, snapshot)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check filesystem isolation"
  end

  test "a Docker command can read the workspace but cannot read a host fixture", %{tmp_dir: root} do
    outside = Path.join(root, "outside.txt")
    File.write!(outside, "Outside fixture")

    assert {:ok, workspace} = Workspace.open(profile: :docker, from: prepare_report())

    try do
      assert {:ok, %{exit_status: 0, output: "Approved report"}} =
               Workspace.run(workspace, ["cat", "report.txt"])

      assert {:ok, %{exit_status: 1, output: output}} = Workspace.run(workspace, ["cat", outside])
      refute output =~ "Outside fixture"
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp prepare_report do
    assert {:ok, workspace} = Workspace.open(profile: :author)

    try do
      assert :ok = Workspace.write(workspace, "report.txt", "Approved report")
      assert {:ok, snapshot} = Workspace.save(workspace)
      snapshot
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp verify_read_only(profile, snapshot) do
    assert {:ok, workspace} = Workspace.open(profile: profile, from: snapshot)

    try do
      assert %{
               read: {:ok, "Approved report"},
               write: {:error, %Workspace.Error{code: :policy_denied, operation: :write}},
               run: {:error, %Workspace.Error{code: :policy_denied, operation: :run}}
             } = RestrictedReport.check(workspace)

      assert {:ok, "Approved report"} = Workspace.read(workspace, "report.txt")
    after
      assert :ok = Workspace.close(workspace)
    end
  end

  defp configure(key, value) do
    previous = Application.fetch_env(:jido_workspace, key)
    Application.put_env(:jido_workspace, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_workspace, key, value)
        :error -> Application.delete_env(:jido_workspace, key)
      end
    end)
  end
end
