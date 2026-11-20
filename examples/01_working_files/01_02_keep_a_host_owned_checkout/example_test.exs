Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.EditCheckoutTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.EditCheckout
  import Jido.Workspace.Examples.LifecycleSupport

  @original "First draft\n"
  @revised "Revised draft\n"

  setup %{tmp_dir: root} do
    configure(Path.join(root, "snapshots"))
    checkout = Path.join(root, "checkout")
    File.mkdir!(checkout)
    File.write!(Path.join(checkout, "draft.txt"), @original)
    put_checkout(:checkout, checkout)
    %{checkout: checkout}
  end

  test "requires an existing absolute directory on a native profile", %{
    tmp_dir: root,
    checkout: checkout
  } do
    put_checkout(:relative, "checkout")
    put_checkout(:missing, Path.join(root, "missing"))
    put_checkout(:file, Path.join(checkout, "draft.txt"))

    link = Path.join(root, "checkout-link")
    File.ln_s!(checkout, link)
    put_checkout(:link, link)
    put_profile(:memory_checkout, Map.put(profile!(:memory), :checkout, checkout))

    assert {:error, %Error{code: :invalid_profile}} = Workspace.open(profile: :relative)
    assert {:error, %Error{code: :invalid_profile}} = Workspace.open(profile: :memory_checkout)
    assert {:error, %Error{code: :not_found}} = Workspace.open(profile: :missing)
    assert {:error, %Error{code: :not_directory}} = Workspace.open(profile: :file)
    assert {:error, %Error{code: :symlink_path}} = Workspace.open(profile: :link)
    refute File.exists?(Path.join(root, "missing"))
  end

  test "snapshot restore cannot overwrite the host directory", %{checkout: checkout} do
    assert {:ok, scratch} = Workspace.open(profile: :memory)
    assert :ok = Workspace.write(scratch, "draft.txt", @revised)
    assert {:ok, snapshot} = Workspace.save(scratch)
    assert :ok = Workspace.close(scratch)

    assert {:error, %Error{code: :checkout_restore_unsupported}} =
             Workspace.open(profile: :checkout, from: snapshot)

    assert File.read!(Path.join(checkout, "draft.txt")) == @original
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to use a native checkout"
  end

  test "an existing Git checkout keeps edits and its index after close", %{
    tmp_dir: root,
    checkout: checkout
  } do
    assert {_, 0} = git(checkout, ["init", "--quiet"])
    assert {_, 0} = git(checkout, ["add", "--", "draft.txt"])

    alias_parent = Path.join(root, "alias")
    File.ln_s!(root, alias_parent)
    put_checkout(:other_path, Path.join(alias_parent, "checkout"))

    {workspace, sandbox} = open_checkout()
    assert {:error, %Error{code: :checkout_busy}} = Workspace.open(profile: :other_path)

    assert {:ok, %Execution{exit_status: 0, output: @revised}} =
             EditCheckout.revise_draft(workspace, @revised)

    assert :ok = Workspace.close(workspace)
    assert :ok = Workspace.close(workspace)
    assert [] = containers(sandbox)
    assert {:error, %Error{code: :closed}} = Workspace.read(workspace, "draft.txt")
    assert File.read!(Path.join(checkout, "draft.txt")) == @revised
    assert {@original, 0} = git(checkout, ["show", ":draft.txt"])

    {reopened, _} = open_checkout()
    assert {:ok, @revised} = Workspace.read(reopened, "draft.txt")
    assert :ok = Workspace.close(reopened)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to verify checkout recovery"
  end

  test "failed admission and owner exit preserve the tree and release its reservation", %{
    checkout: checkout
  } do
    put_profile(:mismatch, %{profile!(:checkout) | require: %{isolation: :gvisor}})
    assert {:error, %Error{code: :unsupported_capability}} = Workspace.open(profile: :mismatch)
    assert File.read!(Path.join(checkout, "draft.txt")) == @original

    owner =
      spawn(fn ->
        receive do
          :exit -> :ok
        end
      end)

    on_exit(fn -> send(owner, :exit) end)
    {workspace, sandbox} = open_checkout(owner: owner)
    assert :ok = Workspace.write(workspace, "draft.txt", @revised)
    monitor = Process.monitor(sandbox.pid)
    send(owner, :exit)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 10_000
    assert [] = containers(sandbox)
    assert File.read!(Path.join(checkout, "draft.txt")) == @revised

    {reopened, _} = open_checkout()
    assert :ok = Workspace.close(reopened)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to test the checkout path binding"
  end

  test "a handle refuses operations if the host moves the directory", %{
    tmp_dir: root,
    checkout: checkout
  } do
    {workspace, _} = open_checkout()
    displaced = Path.join(root, "displaced")
    File.rename!(checkout, displaced)
    File.mkdir!(checkout)
    File.write!(Path.join(checkout, "draft.txt"), "Replacement\n")

    assert {:error, %Error{code: :checkout_changed}} = Workspace.list(workspace)
    assert {:error, %Error{code: :checkout_changed}} = Workspace.delete(workspace, "draft.txt")
    assert {:error, %Error{code: :checkout_changed}} = Workspace.save(workspace)

    assert {:error, %Error{code: :checkout_changed}} =
             Workspace.run(workspace, ["cat", "draft.txt"])

    assert :ok = Workspace.close(workspace)
    assert File.read!(Path.join(checkout, "draft.txt")) == "Replacement\n"
    assert File.read!(Path.join(displaced, "draft.txt")) == @original
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to leave a test command alive after controller loss"
  end

  test "a lost controller leaves the writer and reservation for the host", %{checkout: checkout} do
    {workspace, sandbox} = open_checkout()

    script = """
    mkfifo /tmp/finish
    printf 'Partial draft\n' > draft.txt
    read -r line </tmp/finish
    """

    task =
      Task.async(fn -> Workspace.run(workspace, ["sh", "-c", script], timeout_ms: 30_000) end)

    container = await(fn -> container_running(sandbox) end, "No running test writer", 10_000)
    draft = Path.join(checkout, "draft.txt")

    await(
      fn -> File.read!(draft) == "Partial draft\n" end,
      "The writer did not reach the barrier"
    )

    monitor = Process.monitor(sandbox.pid)
    assert Process.exit(sandbox.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    assert {:error, %Error{code: :quiescence_unknown}} = Task.await(task)
    assert ^container = container_running(sandbox)
    assert {:error, %Error{code: :checkout_busy}} = Workspace.open(profile: :checkout)
    assert {:error, %Error{code: :quiescence_unknown}} = Workspace.save(workspace)
    assert {:error, %Error{code: :cleanup_unconfirmed}} = Workspace.close(workspace)

    assert {_, 0} = docker(["rm", "--force", "--volumes", container])
    assert {:error, %Error{code: :checkout_busy}} = Workspace.open(profile: :checkout)
    assert [reservation] = containers(sandbox)
    assert {_, 0} = docker(["rm", reservation])

    {reopened, _} = open_checkout()
    assert {:ok, "Partial draft\n"} = Workspace.read(reopened, "draft.txt")
    assert :ok = Workspace.close(reopened)
  end

  defp open_checkout(opts \\ []) do
    assert {:ok, workspace} = Workspace.open([profile: :checkout] ++ opts)
    {_, sandbox} = provider(workspace, :native)

    on_exit(fn ->
      case containers(sandbox) do
        [] -> :ok
        ids -> assert {_, 0} = docker(["rm", "--force", "--volumes"] ++ ids)
      end
    end)

    {workspace, sandbox}
  end

  defp put_checkout(name, checkout),
    do: put_profile(name, Map.put(profile!(:docker), :checkout, checkout))

  defp put_profile(name, profile) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, name, profile))
  end

  defp profile!(name), do: Application.fetch_env!(:jido_workspace, :profiles) |> Map.fetch!(name)

  defp git(checkout, args),
    do: System.cmd("git", ["-C", checkout] ++ args, stderr_to_stdout: true)
end
