defmodule Mix.Tasks.JidoShell.InstallTest do
  use ExUnit.Case, async: true
  import Igniter.Test

  test "correct notice is posted" do
    test_project()
    |> Igniter.compose_task("jido_shell.install", [])
    |> assert_has_notice("""
    Jido Shell is included in Jido Workspace.

    Checkout the quickstart guide:
    https://github.com/agentjido/jido_workspace/blob/main/docs/shell/README.md

    """)
  end
end
