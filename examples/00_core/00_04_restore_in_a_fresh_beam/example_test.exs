Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.PersistedReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  alias Jido.Workspace.Error
  alias Jido.Workspace.Examples.PersistedReport

  test "a fresh BEAM uses a JSON-decoded reference to restore bytes and an empty directory",
       %{tmp_dir: root} do
    report = <<"Report from another BEAM\n", 0, 255>>
    reference = Path.join(root, "report.json")
    assert {:ok, _snapshot} = in_fresh_beam(root, :export, [:memory, report, reference])

    assert {:ok, %{report: ^report, empty_entries: []}} =
             in_fresh_beam(root, :restore, [:memory, reference])
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to reopen a memory snapshot in Docker"
  end

  test "a fresh BEAM can reopen the saved memory tree in Docker", %{tmp_dir: root} do
    report = "Report for Docker\n"
    reference = Path.join(root, "report.json")
    assert {:ok, _snapshot} = in_fresh_beam(root, :export, [:memory, report, reference])

    assert {:ok, %{report: ^report, empty_entries: []}} =
             in_fresh_beam(root, :restore, [:docker, reference])
  end

  test "corruption of a later save leaves the previous reference usable", %{tmp_dir: root} do
    first = Path.join(root, "first.json")
    second = Path.join(root, "second.json")
    assert {:ok, _snapshot} = in_fresh_beam(root, :export, [:memory, "Original report", first])
    assert {:ok, snapshot} = in_fresh_beam(root, :export, [:memory, "Updated report", second])
    File.write!(Path.join(store(root), snapshot.digest), "corrupt bundle")

    assert {:error, %Error{code: :invalid_snapshot}} =
             in_fresh_beam(root, :restore, [:memory, second])

    assert {:ok, %{report: "Original report"}} =
             in_fresh_beam(root, :restore, [:memory, first])
  end

  defp in_fresh_beam(root, operation, args) do
    code_paths = Enum.flat_map(:code.get_path(), &[~c"-pa", Path.expand(&1) |> to_charlist()])
    options = %{connection: :standard_io, args: [~c"+S", ~c"2:2" | code_paths], wait_boot: 15_000}
    {:ok, peer, _node} = :peer.start_link(options)

    try do
      configure(peer, root)

      assert {:ok, _} =
               :peer.call(peer, Application, :ensure_all_started, [:jido_workspace], 15_000)

      :peer.call(peer, Code, :require_file, [Path.join(__DIR__, "example.ex")], 15_000)
      :peer.call(peer, PersistedReport, operation, args, 15_000)
    after
      :peer.stop(peer)
    end
  end

  defp configure(peer, root) do
    profiles = %{
      memory: %{provider: :memory, policy: :full_access, store: "reports"},
      docker: %{
        provider: :docker,
        policy: :full_access,
        image: System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest"),
        store: "reports",
        require: %{isolation: :container, network: :disabled}
      }
    }

    :ok = :peer.call(peer, Application, :put_env, [:jido_workspace, :profiles, profiles])

    :ok =
      :peer.call(peer, Application, :put_env, [
        :jido_workspace,
        :stores,
        %{"reports" => store(root)}
      ])
  end

  defp store(root), do: Path.join(root, "snapshots")
end
