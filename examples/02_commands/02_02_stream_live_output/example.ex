defmodule Jido.Workspace.Examples.FollowOutput do
  @moduledoc "Read live command output as a stream of byte slices."

  alias Jido.Workspace

  def follow(workspace, execution_id, offset \\ 0) do
    Stream.resource(
      fn -> offset end,
      fn
        :done -> {:halt, :done}
        cursor -> read(workspace, execution_id, cursor)
      end,
      fn _ -> :ok end
    )
  end

  defp read(workspace, execution_id, cursor) do
    case Workspace.output(workspace, execution_id, cursor) do
      {:ok, %{done?: true} = slice} ->
        {[slice], :done}

      {:ok, %{bytes: "", dropped_bytes: 0, next_offset: next}} ->
        Process.sleep(25)
        {[], next}

      {:ok, %{next_offset: next} = slice} ->
        {[slice], next}

      {:error, _} = error ->
        {[error], :done}
    end
  end
end
