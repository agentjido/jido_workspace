defmodule Jido.Workspace.EmbeddedLua do
  @moduledoc false

  alias Jido.Workspace.{CommandIO, Schemas}

  @draft {__MODULE__, :draft}
  @max_bytes 1_048_576
  @max_files 128
  @poll_ms 10

  def run([script | args], opts, read) do
    with {:ok, path} <- scoped_path(opts.cwd, script) do
      # The worker can read the tree and stage data. Only its caller can
      # publish the files. The link also stops evaluation if that caller dies.
      trap_exit = Process.flag(:trap_exit, true)
      task = Task.async(fn -> evaluate(path, script, args, opts, read) end)

      try do
        await(task, opts)
      after
        Task.shutdown(task, :brutal_kill)
        Process.flag(:trap_exit, trap_exit)
      end
    end
  end

  def run([], _, _), do: {:error, :invalid_input}

  defp await(task, opts) do
    remaining = opts.deadline - System.monotonic_time(:millisecond)

    cond do
      :atomics.get(opts.stop, 1) == 1 ->
        {:stopped, :cancelled}

      remaining <= 0 ->
        {:stopped, :timed_out}

      true ->
        case Task.yield(task, min(remaining, @poll_ms)) do
          {:ok, result} ->
            result

          {:exit, _} ->
            CommandIO.append(opts.io_buffer, "Lua worker stopped during evaluation\n")
            :failed

          nil ->
            await(task, opts)
        end
    end
  end

  defp evaluate(path, script, args, opts, read) do
    Process.flag(:max_heap_size, %{
      size: 2_000_000,
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })

    case read.(path, @max_bytes) do
      {:ok, source} -> eval(source, script, args, opts, read)
      {:error, _} -> {:error, :start_failed}
    end
  end

  defp eval(source, script, args, opts, read) do
    argv = Map.new(Enum.with_index([script | args]), fn {value, index} -> {index, value} end)

    lua =
      Lua.new(max_call_depth: 128, max_string_bytes: @max_bytes)
      |> Lua.set!(:io, nil)
      |> Lua.set!(:os, nil)
      |> Lua.set!(:package, nil)
      |> Lua.set!(:debug, nil)
      |> Lua.set!(:arg, argv)
      |> Lua.set!(:print, fn values -> print(values, opts.io_buffer) end)
      |> Lua.set!([:workspace, :read], fn values, lua ->
        read_file(values, lua, opts.cwd, read)
      end)
      |> Lua.set!([:workspace, :write], fn values, lua -> stage_file(values, lua, opts.cwd) end)
      |> Lua.put_private(@draft, {%{}, 0})

    {_, result} = Lua.eval!(lua, source, decode: false, source: script)
    {files, _} = Lua.get_private!(result, @draft)
    {:ok, Enum.sort(files)}
  rescue
    error in [Lua.CompilerException, Lua.RuntimeException] ->
      CommandIO.append(opts.io_buffer, Exception.message(error) <> "\n")
      :failed
  end

  defp read_file([path], lua, cwd, read) do
    with {:ok, path} <- scoped_path(cwd, path) do
      {files, _} = Lua.get_private!(lua, @draft)

      case Map.fetch(files, path) do
        {:ok, bytes} -> [bytes]
        :error -> read_draft_source(read, path, lua)
      end
    else
      _ -> {:error, "workspace.read requires a relative file path", lua}
    end
  end

  defp read_file(_, lua, _, _), do: {:error, "workspace.read requires one file path", lua}

  defp read_draft_source(read, path, lua) do
    case read.(path, @max_bytes) do
      {:ok, bytes} -> [bytes]
      {:error, _} -> {:error, "workspace.read could not read the file", lua}
    end
  end

  defp stage_file([path, bytes], lua, cwd) when is_binary(bytes) do
    with {:ok, path} <- scoped_path(cwd, path) do
      {files, size} = Lua.get_private!(lua, @draft)
      new_size = size - byte_size(Map.get(files, path, "")) + byte_size(bytes)
      files = Map.put(files, path, bytes)

      if new_size <= @max_bytes and map_size(files) <= @max_files,
        do: {[true], Lua.put_private(lua, @draft, {files, new_size})},
        else: {:error, "workspace.write exceeded the draft limit", lua}
    else
      _ -> {:error, "workspace.write requires a relative file path", lua}
    end
  end

  defp stage_file(_, lua, _), do: {:error, "workspace.write requires a path and bytes", lua}

  defp scoped_path(cwd, path) do
    with true <- path != "." and Schemas.relative_path?(path),
         full = if(cwd == ".", do: path, else: cwd <> "/" <> path),
         true <- Schemas.relative_path?(full) do
      {:ok, full}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp print(values, buffer) do
    line = Enum.map_join(values, "\t", &text/1)
    CommandIO.append(buffer, line <> "\n")
    []
  end

  defp text(nil), do: "nil"
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text({:tref, _}), do: "table"
  defp text(_), do: "value"
end
