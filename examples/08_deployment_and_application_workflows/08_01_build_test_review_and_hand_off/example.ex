Code.require_file("../../02_commands/02_02_stream_live_output/example.ex", __DIR__)

defmodule Jido.Workspace.Examples.BuildAndReview do
  @moduledoc "Run two tool stages, follow the output, and save the checked tree."

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.FollowOutput

  def run(workspace, build, test, on_output) do
    with :ok <- run_stage(workspace, :build, build, on_output),
         :ok <- run_stage(workspace, :test, test, on_output) do
      Workspace.save(workspace)
    end
  end

  defp run_stage(workspace, stage, {argv, opts}, on_output) do
    tag = make_ref()

    reader =
      Task.async(fn ->
        id =
          receive do
            {:workspace_command_started, ^tag, id} -> id
            {^tag, result} -> execution_id(result)
          end

        if id, do: follow(workspace, stage, id, on_output), else: :ok
      end)

    result = Workspace.run(workspace, argv, Keyword.put(opts, :notify_start, {reader.pid, tag}))
    send(reader.pid, {tag, result})
    observed = Task.await(reader, :infinity)

    case result do
      {:ok, %Execution{status: :exited, exit_status: 0}} -> stage_result(stage, observed)
      {_, reason} -> stage_result(stage, {:error, reason})
    end
  end

  defp execution_id({:ok, %Execution{id: id}}), do: id
  defp execution_id({:error, %Error{details: %{execution_id: id}}}), do: id
  defp execution_id(_), do: nil

  defp follow(workspace, stage, id, on_output) do
    workspace
    |> FollowOutput.follow(id)
    |> Enum.reduce_while(:ok, fn
      {:error, _} = error, :ok ->
        {:halt, error}

      slice, :ok ->
        on_output.(stage, id, slice)
        {:cont, :ok}
    end)
  end

  defp stage_result(_, :ok), do: :ok
  defp stage_result(stage, {:error, reason}), do: {:error, %{stage: stage, reason: reason}}
end
