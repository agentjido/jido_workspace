defmodule SearchSpike.Backend do
  @moduledoc false
  @behaviour Jido.Shell.Backend
  def init(config), do: {:ok, config}
  def cwd(state), do: {:ok, "/", state}
  def cd(state, _), do: {:ok, state}
  def terminate(_), do: :ok
  def cancel(_, pid), do: Task.Supervisor.terminate_child(Jido.Shell.CommandTaskSupervisor, pid)

  # Benchmark command only. The dependency's command registry is unchanged.
  def execute(state, command, [], opts) do
    session = Keyword.fetch!(opts, :session_state)

    {:ok, pid} =
      Task.Supervisor.start_child(Jido.Shell.CommandTaskSupervisor, fn ->
        try do
          ["grep", mode, pattern] = String.split(command, " ", parts: 3)
          search = Map.get(state, :search, &search/3)
          output = search.(session.workspace_id, mode, pattern)
          send(state.session_pid, {:command_event, {:output, output}})
          send(state.session_pid, {:command_finished, {:ok, nil}})
        rescue
          error ->
            send(
              state.session_pid,
              {:command_finished,
               {:error,
                Jido.Shell.Error.command(:search_failed, %{reason: Exception.message(error)})}}
            )
        end
      end)

    {:ok, pid, state}
  end

  def search(id, mode, pattern) do
    matcher =
      case mode do
        "literal" ->
          compiled = :binary.compile_pattern(pattern)
          fn line -> :binary.match(line, compiled) != :nomatch end

        "regex" ->
          compiled = Regex.compile!(pattern)
          fn line -> Regex.match?(compiled, line) end
      end

    walk(id, "/", matcher) |> IO.iodata_to_binary()
  end

  defp walk(id, path, matcher) do
    {:ok, entries} = Jido.Shell.VFS.list_dir(id, path)

    Enum.map(entries, fn entry ->
      next = Path.join(path, entry.name)

      case entry do
        %Jido.VFS.Stat.Dir{} ->
          walk(id, next, matcher)

        %Jido.VFS.Stat.File{} ->
          {:ok, content} = Jido.Shell.VFS.read_file(id, next)
          lines = :binary.split(content, "\n", [:global])
          lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines

          lines
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, number} ->
            if matcher.(line),
              do: [[".", next, ":", Integer.to_string(number), ":", line, "\n"]],
              else: []
          end)
      end
    end)
  end
end

defmodule SearchSpike.Fixture do
  @moduledoc false
  def content(index, bytes) do
    header = "file_id=#{index} token=needle_rare status=error code=E123\n"
    common = "def handle_request(input), do: {:ok, input} # common_token\n"
    body = header <> String.duplicate(common, div(bytes, byte_size(common)) + 1)
    binary_part(body, 0, bytes - 1) <> "\n"
  end

  def normalized(output), do: output |> String.split("\n", trim: true) |> Enum.sort()
end
