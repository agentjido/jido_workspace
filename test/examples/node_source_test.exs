defmodule Jido.Workspace.Deploy.NodeSourceTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Jido.Workspace.Deploy
  alias Jido.Workspace.Deploy.Test.NodeApp
  alias Jido.Workspace.Sandbox

  setup do
    {:ok, sandbox} = Sandbox.open()
    on_exit(fn -> Sandbox.destroy(sandbox) end)
    {:ok, target} = Deploy.source_target(sandbox, "node-counter", stage: :test, roles: [:web])
    {:ok, session} = Deploy.connect(target)
    %{sandbox: sandbox, target: target, session: session, recipe: NodeApp.recipe(NodeApp.port())}
  end

  test "Node uses release directories, restart, verification, and explicit recovery", ctx do
    recipe = ctx.recipe
    port = recipe.service.args |> List.last() |> String.to_integer()
    a = NodeApp.artifact(1)
    {:ok, plan_a} = Deploy.prepare(ctx.session, a, recipe: recipe)
    {:ok, id_a} = Deploy.apply(ctx.session, plan_a)
    assert {:ok, %{status: :succeeded} = first} = Deploy.await(ctx.session, id_a)
    assert first.target.stage == :test
    assert NodeApp.get(port, "/add") =~ ~s("count":1)

    assert Enum.map(first.steps, & &1.phase) == [
             :check_target,
             :stage,
             :prepare,
             :activate,
             :verify
           ]

    {:ok, %{identity: %{service: first_service}}} = Deploy.inspect(ctx.session)

    {:ok, stale} = Deploy.prepare(ctx.session, a, recipe: recipe)
    {:ok, plan_b} = Deploy.prepare(ctx.session, NodeApp.artifact(2), recipe: recipe)
    {:ok, id_b} = Deploy.apply(ctx.session, plan_b)
    assert {:ok, %{status: :succeeded}} = Deploy.await(ctx.session, id_b)
    assert NodeApp.get(port) =~ ~s("count":0)
    assert NodeApp.get(port, "/add") =~ ~s("count":2)
    assert {:ok, %{status: :stopped}} = Sandbox.service_status(ctx.sandbox, first_service)
    {:ok, stale_id} = Deploy.apply(ctx.session, stale)

    assert {:ok, %{status: :failed, evidence: :stale_target_or_payload}} =
             Deploy.await(ctx.session, stale_id)

    {:ok, bad} =
      Deploy.prepare(ctx.session, NodeApp.artifact(3, bad_verify: true), recipe: recipe)

    {:ok, failed_id} = Deploy.apply(ctx.session, bad)
    assert {:ok, %{status: :recovery_required}} = Deploy.await(ctx.session, failed_id)
    {:ok, ordinary} = Deploy.prepare(ctx.session, a, recipe: recipe)
    assert {:error, :recovery_required} = Deploy.apply(ctx.session, ordinary)

    {:ok, recovery} = Deploy.recover(ctx.session, failed_id, a, recipe: recipe)
    {:ok, recovery_id} = Deploy.apply(ctx.session, recovery)

    assert {:ok, %{status: :succeeded, recovery_of: ^failed_id}} =
             Deploy.await(ctx.session, recovery_id)

    assert NodeApp.get(port) =~ ~s("version":1)
    assert File.dir?(Path.join([ctx.sandbox.root, ctx.target.path, "shared"]))
  end

  test "failed preparation leaves current unchanged; generated build files are permitted", ctx do
    recipe = %{ctx.recipe | prepare: [{"node", ["-e", "process.exit(9)"]}]}
    {:ok, plan} = Deploy.prepare(ctx.session, NodeApp.artifact(1), recipe: recipe)
    {:ok, id} = Deploy.apply(ctx.session, plan)
    assert {:ok, %{status: :failed}} = Deploy.await(ctx.session, id)
    assert {:ok, %{identity: %{current: nil}}} = Deploy.inspect(ctx.session)

    recipe = %{
      ctx.recipe
      | prepare: [{"node", ["-e", "require('fs').writeFileSync('generated.txt', 'ok')"]}]
    }

    {:ok, good} = Deploy.prepare(ctx.session, NodeApp.artifact(1), recipe: recipe)
    {:ok, good_id} = Deploy.apply(ctx.session, good)
    assert {:ok, %{status: :succeeded}} = Deploy.await(ctx.session, good_id)
  end
end
