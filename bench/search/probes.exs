defmodule SearchSpike.Probes do
  @moduledoc false

  # A frozen view for repeated searches. Build it again after file changes.
  def snapshot(id, path \\ "/") do
    {:ok, entries} = Jido.Shell.VFS.list_dir(id, path)

    Enum.flat_map(entries, fn entry ->
      next = Path.join(path, entry.name)

      case entry do
        %Jido.VFS.Stat.Dir{} ->
          snapshot(id, next)

        %Jido.VFS.Stat.File{} ->
          {:ok, content} = Jido.Shell.VFS.read_file(id, next)
          [{next, content}]
      end
    end)
  end

  def search(files, mode, pattern, algorithm, workers, opts \\ []) do
    compiled =
      case mode do
        "literal" ->
          if pattern == "" or String.contains?(pattern, "\n"),
            do: raise("Use nonempty single-line text")

          :binary.compile_pattern(pattern)

        "regex" ->
          Regex.compile!(pattern, if(algorithm == :offsets, do: "m", else: ""))
      end

    scan = fn batch ->
      Enum.map(batch, fn {path, content} ->
        case Keyword.get(opts, :output, :lines) do
          :files ->
            found =
              if mode == "literal",
                do: :binary.match(content, compiled) != :nomatch,
                else: content != "" and Regex.match?(compiled, content)

            if found, do: [".", path, "\n"], else: []

          :lines ->
            case algorithm do
              :lines ->
                lines(path, content, mode, compiled)

              :offsets ->
                offsets(
                  path,
                  content,
                  mode,
                  compiled,
                  Keyword.get(opts, :max_per_file, :infinity)
                )
            end
        end
      end)
      |> IO.iodata_to_binary()
    end

    if workers == 1 or files == [] do
      scan.(files)
    else
      files
      |> Enum.chunk_every(ceil(length(files) / workers))
      |> Task.async_stream(scan, max_concurrency: workers, ordered: false, timeout: 300_000)
      |> Enum.map(fn {:ok, output} -> output end)
      |> IO.iodata_to_binary()
    end
  end

  defp lines(path, content, mode, compiled) do
    rows = :binary.split(content, "\n", [:global])
    rows = if List.last(rows) == "", do: Enum.drop(rows, -1), else: rows

    rows
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      matches =
        case mode do
          "literal" -> :binary.match(line, compiled) != :nomatch
          "regex" -> Regex.match?(compiled, line)
        end

      if matches, do: [row(path, number, line)], else: []
    end)
  end

  # Probe scope: line-local regular expressions. Whole-file regex evaluation
  # can differ for lookaround, absolute anchors, and expressions that cross lines.
  defp offsets(path, content, mode, compiled, limit) do
    matches =
      case mode do
        "literal" ->
          :binary.matches(content, compiled)

        "regex" ->
          Regex.scan(compiled, content, return: :index, capture: :first) |> Enum.map(&hd/1)
      end

    size = byte_size(content)

    {_, _, rows, _} =
      Enum.reduce_while(matches, {0, 1, [], 0}, fn {position, length},
                                                   {cursor, number, rows, count} = acc ->
        cond do
          count == limit ->
            {:halt, acc}

          position < cursor or cursor == size ->
            {:cont, acc}

          true ->
            if :binary.match(binary_part(content, position, length), "\n") != :nomatch,
              do: raise("This probe does not support matches across lines")

            prefix = binary_part(content, cursor, position - cursor)
            newlines = :binary.matches(prefix, "\n")

            start =
              case List.last(newlines) do
                nil -> cursor
                {last, 1} -> cursor + last + 1
              end

            stop =
              case :binary.match(content, "\n", scope: {position, size - position}) do
                :nomatch -> size
                {index, 1} -> index
              end

            line_number = number + Kernel.length(newlines)
            line = binary_part(content, start, stop - start)

            {:cont,
             {min(stop + 1, size), line_number + 1, [row(path, line_number, line) | rows],
              count + 1}}
        end
      end)

    Enum.reverse(rows)
  end

  defp row(path, number, line), do: [".", path, ":", Integer.to_string(number), ":", line, "\n"]
end
