defmodule Jido.Workspace.Examples.AnswerPrompt do
  @moduledoc "Send a line of input to a program in a workspace."

  alias Jido.Workspace

  @program ~S"""
  printf 'name?\n'
  IFS= read -r name || exit 2
  printf '%s\n' "$name" > name.txt
  printf 'hello %s\n' "$name"
  """

  def run(workspace) do
    Workspace.run(workspace, ["sh", "-c", @program], stdin: :pipe, timeout_ms: 20_000)
  end

  def answer(workspace, execution_id, line) do
    Workspace.input(workspace, execution_id, line <> "\n")
  end
end
