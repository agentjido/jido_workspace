Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.PersistedReportTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  alias Jido.Workspace.Error
  alias Jido.Workspace.Examples.PersistedReport

  test "a fresh BEAM uses a JSON-decoded reference to restore bytes and an empty directory",
       ctx do
    report = <<"Report from another BEAM\n", 0, 255>>
    assert {:ok, snapshot} = in_fresh_beam(ctx.tmp_dir, :export, [:report, report])
    reference = snapshot |> Jason.encode!() |> Jason.decode!()

    assert {:ok, %{report: ^report, empty_entries: []}} =
             in_fresh_beam(ctx.tmp_dir, :restore, [:report, reference])
  end

  test "corruption of a later save leaves the previous reference usable", ctx do
    assert {:ok, first} = in_fresh_beam(ctx.tmp_dir, :export, [:report, "Original report"])
    assert {:ok, second} = in_fresh_beam(ctx.tmp_dir, :export, [:report, "Updated report"])
    File.write!(Path.join(ctx.tmp_dir, second.digest), "corrupt bundle")

    assert {:error, %Error{code: :invalid_snapshot}} =
             in_fresh_beam(ctx.tmp_dir, :restore, [:report, second])

    assert {:ok, %{report: "Original report"}} =
             in_fresh_beam(ctx.tmp_dir, :restore, [:report, first])
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
    profiles = %{report: %{provider: :memory, policy: :full_access, store: "reports"}}
    :ok = :peer.call(peer, Application, :put_env, [:jido_workspace, :profiles, profiles])

    :ok =
      :peer.call(peer, Application, :put_env, [:jido_workspace, :stores, %{"reports" => root}])
  end
end
