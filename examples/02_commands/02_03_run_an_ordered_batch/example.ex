defmodule Jido.Workspace.Examples.PrepareReport do
  @moduledoc "Write a draft, check its inputs, and save a successful batch."

  alias Jido.Workspace

  def prepare(workspace, extra_inputs \\ []) do
    steps = [
      {:mkdir, "reports"},
      {:write, "reports/draft.txt", "Sales report\n"},
      {:run, ["cat", "draft.txt" | extra_inputs], [cwd: "reports", output_limit: 512]},
      {:write, "reports/checked.txt", "Inputs checked\n"}
    ]

    case Workspace.batch(workspace, steps) do
      {:ok, %{status: :completed}} -> Workspace.save(workspace)
      result -> result
    end
  end
end
