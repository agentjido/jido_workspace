defmodule Jido.Workspace.ProfileTest do
  use ExUnit.Case, async: false

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Snapshot}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    image = System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest")
    common = %{policy: :full_access, store: "reports"}

    profiles = %{
      memory: Map.merge(common, %{provider: :memory, require: %{isolation: :mediated}}),
      read_only: Map.merge(common, %{provider: :memory, policy: :read_only}),
      network_mismatch:
        Map.merge(common, %{provider: :memory, require: %{isolation: :container}}),
      docker:
        Map.merge(common, %{
          provider: :docker,
          image: image,
          require: %{isolation: :container, network: :disabled}
        })
    }

    store = Path.join(root, "reports")
    configure(:profiles, profiles)
    configure(:stores, %{"reports" => store})
    %{store: store}
  end

  test "the memory facade accepts literal argv, restores a snapshot, and deduplicates identical saves" do
    snapshot = report(:memory)
    assert {:ok, ^snapshot} = Snapshot.parse(Jason.decode!(Jason.encode!(snapshot)))

    with_workspace(:memory, snapshot, fn ws ->
      assert {:ok, "report\n"} = Workspace.read(ws, "reports/output data.txt")
      assert {:ok, []} = Workspace.list(ws, "empty")
      assert {:ok, ^snapshot} = Workspace.save(ws)
    end)
  end

  test "invalid profile options fail closed and a read-only restore denies changes" do
    assert {:error, %Error{code: :unknown_profile}} = Workspace.open(profile: :missing)

    assert {:error, %Error{code: :invalid_input}} =
             Workspace.open(profile: :memory, policy: :read_only)

    assert {:error, %Error{code: :unsupported_capability}} =
             Workspace.open(profile: :network_mismatch)

    assert {:error, %Error{code: :invalid_input}} = Workspace.open(from: %{})
    snapshot = report(:memory)

    with_workspace(:read_only, snapshot, fn ws ->
      assert {:ok, "report\n"} = Workspace.read(ws, "reports/output data.txt")
      assert {:error, %Error{code: :policy_denied}} = Workspace.write(ws, "forbidden", "no")

      assert {:error, %Error{code: :policy_denied}} =
               Workspace.run(ws, ["cat", "reports/input data.txt"])

      assert {:error, %Error{code: :policy_denied}} = Workspace.save(ws)
    end)
  end

  test "a damaged snapshot fails validation before open", %{store: store} do
    snapshot = report(:memory)
    File.write!(Path.join(store, snapshot.digest), "corrupt")

    assert {:error, %Error{code: :invalid_snapshot}} =
             Workspace.open(profile: :memory, from: snapshot)
  end

  test "a running command reserves the tree until it finishes" do
    with_workspace(:memory, nil, fn ws ->
      run = Task.async(fn -> Workspace.run(ws, ["sleep", "1"], timeout_ms: 5_000) end)
      wait_until_running(ws, 500)
      assert {:error, %Error{code: :busy}} = Workspace.save(ws)
      assert {:error, %Error{code: :busy}} = Workspace.write(ws, "busy.txt", "no")
      assert {:ok, %{exit_status: 0}} = Task.await(run)
      assert {:ok, %{kind: "snapshot"}} = Workspace.save(ws)
    end)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to check the shared facade on Docker"
  end

  @tag :integration
  test "the same workflow and snapshot run on memory and Docker" do
    memory = report(:memory)
    assert ^memory = report(:docker)

    with_workspace(:docker, memory, fn ws ->
      assert {:ok, "report\n"} = Workspace.read(ws, "reports/output data.txt")
      assert {:ok, []} = Workspace.list(ws, "empty")

      assert {:ok, %{exit_status: 0, output: "report\n"}} =
               Workspace.run(ws, ["cat", "output data.txt"], cwd: "reports")
    end)
  end

  defp with_workspace(profile, snapshot, fun) do
    opts = if snapshot, do: [profile: profile, from: snapshot], else: [profile: profile]
    assert {:ok, ws} = Workspace.open(opts)

    try do
      fun.(ws)
    after
      assert :ok = Workspace.close(ws)
    end
  end

  defp report(profile) do
    with_workspace(profile, nil, fn ws ->
      assert :ok = Workspace.mkdir(ws, "reports")
      assert :ok = Workspace.mkdir(ws, "empty")
      assert :ok = Workspace.write(ws, "reports/input data.txt", "report\n")

      assert {:ok, %{exit_status: 0}} =
               Workspace.run(ws, ["cp", "input data.txt", "output data.txt"], cwd: "reports")

      assert {:ok, "report\n"} = Workspace.read(ws, "reports/output data.txt")
      assert {:ok, snapshot} = Workspace.save(ws)
      snapshot
    end)
  end

  defp wait_until_running(ws, remaining) when remaining > 0 do
    case Workspace.info(ws) do
      {:ok, %{session: :running}} ->
        :ok

      _ ->
        receive do
        after
          10 -> wait_until_running(ws, remaining - 10)
        end
    end
  end

  defp wait_until_running(_, _), do: flunk("the command did not start")

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
