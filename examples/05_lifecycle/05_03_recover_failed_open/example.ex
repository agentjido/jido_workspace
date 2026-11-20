defmodule Jido.Workspace.Examples.ReopenReport do
  @moduledoc "Use a saved report to retry an open after the allocation wait expires."

  alias Jido.Workspace
  alias Jido.Workspace.Error

  def reopen(profile, snapshot, timeout_ms) do
    case Workspace.open(profile: profile, from: snapshot, timeout_ms: timeout_ms) do
      {:error, %Error{code: :open_timeout} = error} ->
        {:retry_open, snapshot, error}

      result ->
        result
    end
  end
end
