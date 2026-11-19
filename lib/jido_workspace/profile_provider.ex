defmodule Jido.Workspace.ProfileProvider do
  @moduledoc false

  alias Jido.Shell.CommandRunner
  alias Jido.Shell.ShellSession.State
  alias Jido.VFS.Capture
  alias Jido.Workspace
  alias Jido.Workspace.{Entry, Sandbox, SnapshotStore}
  alias Jido.Workspace.Sandbox.Files

  @capabilities %{
    memory: %{isolation: :mediated, network: :disabled}
  }
  @output_key {__MODULE__, :output}

  def open(%{provider: :memory} = profile, capture) do
    with :ok <- admit(@capabilities.memory, profile.require),
         {:ok, workspace} <- Workspace.open() do
      initialize({:memory, workspace}, capture)
    end
  end

  def open(profile, capture) do
    with {:ok, sandbox} <-
           Sandbox.open(provider: profile.provider, image: profile.image, owner: self()) do
      provider = {:native, sandbox}

      case admit(Sandbox.capabilities(sandbox), profile.require) do
        :ok -> initialize(provider, capture)
        error -> release_failed_open(provider, error)
      end
    end
  end

  def close({:memory, workspace}), do: Workspace.close(workspace)
  def close({:native, sandbox}), do: Sandbox.destroy(sandbox)

  def file({:memory, workspace}, operation, [path | rest]) do
    result = apply(Workspace, operation, [workspace, absolute(path) | rest])

    case {operation, result} do
      {:list, {:ok, entries}} ->
        {:ok, Enum.map(entries, &%{&1 | path: String.trim_leading(&1.path, "/")})}

      {_, result} ->
        result
    end
  end

  def file({:native, sandbox}, :list, [path]), do: list_native(sandbox.root, path)
  def file({:native, sandbox}, :delete, [path]), do: delete_native(sandbox.root, path)

  def file({:native, sandbox}, operation, args)
      when operation in [:read, :write, :mkdir],
      do: apply(Sandbox, operation, [sandbox | args])

  def capture({:memory, workspace}) do
    with {:ok, capture, _} <- Workspace.capture(workspace), do: {:ok, capture}
  end

  def capture({:native, sandbox}) do
    with {:ok, entries} <- Files.capture(sandbox.root, ".", true, SnapshotStore.capture_budget()),
         {:ok, entries} <- portable_entries(entries) do
      {:ok, %Capture{entries: entries}}
    end
  end

  def run({:memory, workspace}, argv, opts) do
    cwd = absolute(opts.cwd)

    with {:ok, %Workspace.Info{id: namespace}} <- Workspace.info(workspace),
         {:ok, _} <- Workspace.list(workspace, cwd),
         {:ok, shell} <- State.new(%{id: namespace, workspace_id: namespace, cwd: cwd}) do
      Process.put(@output_key, {"", false})

      try do
        with {:ok, _} <-
               CommandRunner.execute_argv(shell, argv, &collect(&1, opts.output_limit)) do
          {output, truncated} = Process.get(@output_key)
          {:ok, %{status: :exited, exit_status: 0, output: output, truncated: truncated}}
        end
      after
        Process.delete(@output_key)
      end
    end
  end

  def run({:native, sandbox}, [command | args], opts) do
    with {:ok, cwd} <- Files.path(sandbox.root, opts.cwd),
         {:ok, %{type: :directory}} <- File.stat(cwd) do
      Sandbox.exec(sandbox, command, args,
        dir: opts.cwd,
        timeout: opts.timeout_ms,
        output_limit: opts.output_limit
      )
      |> native_result()
    else
      {:ok, _} -> {:error, :not_directory}
      error -> error
    end
  end

  defp native_result(result) do
    case result do
      {:ok, %{status: :exited, exit_status: exit_status}} when is_integer(exit_status) ->
        result

      {:ok, %{status: :timed_out} = execution} ->
        {:ok, %{execution | exit_status: nil}}

      _ ->
        {:error, :quiescence_unknown}
    end
  end

  defp initialize(provider, capture) do
    case restore(provider, capture) do
      :ok -> {:ok, provider}
      error -> release_failed_open(provider, error)
    end
  end

  defp release_failed_open(provider, error) do
    case close(provider) do
      :ok -> error
      _ -> {:error, :cleanup_unconfirmed}
    end
  end

  defp admit(capabilities, requirements) when is_map(capabilities) do
    Enum.find_value(requirements, :ok, fn {key, value} ->
      if Map.get(capabilities, key) != value, do: {:error, {:unsupported_capability, key}}
    end)
  end

  defp admit(_, _), do: {:error, :quiescence_unknown}

  defp restore(_, nil), do: :ok

  defp restore({:memory, workspace}, capture) do
    with {:ok, _, revision} <- Workspace.capture(workspace),
         {:ok, _} <- Workspace.replace(workspace, capture, expected: revision),
         do: :ok
  end

  defp restore({:native, sandbox} = provider, %Capture{entries: entries} = saved) do
    with :ok <- restore_entries(sandbox, Enum.sort(entries)),
         {:ok, ^saved} <- capture(provider) do
      :ok
    else
      {:ok, _} -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp restore_entries(sandbox, entries) do
    Enum.reduce_while(entries, :ok, fn {path, entry}, :ok ->
      case restore_entry(sandbox, path, entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp restore_entry(sandbox, path, %{type: :directory}), do: Sandbox.mkdir(sandbox, path)

  defp restore_entry(sandbox, path, %{type: :file, content: bytes, metadata: metadata}) do
    mode = if Map.get(metadata, :mode) == :executable, do: 0o755, else: 0o644
    Sandbox.write(sandbox, path, bytes, mode)
  end

  defp portable_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      {path, %{type: :directory}}, {:ok, result} ->
        {:cont, {:ok, Map.put(result, path, %{type: :directory, metadata: %{}})}}

      {path, %{bytes: bytes, mode: mode}}, {:ok, result} ->
        entry = %{type: :file, content: bytes, metadata: %{mode: mode(mode)}}
        {:cont, {:ok, Map.put(result, path, entry)}}

      _, _ ->
        {:halt, {:error, :invalid_snapshot}}
    end)
  end

  defp collect({channel, chunk}, limit) when channel in [:output, :output_stderr] do
    {output, truncated} = Process.get(@output_key)
    bytes = IO.iodata_to_binary(chunk)
    retained = min(byte_size(bytes), limit - byte_size(output))

    Process.put(
      @output_key,
      {output <> binary_part(bytes, 0, retained), truncated or retained < byte_size(bytes)}
    )

    :ok
  end

  defp collect(_, _), do: :ok

  defp list_native(root, path) do
    with {:ok, full} <- Files.path(root, path),
         {:ok, names} <- File.ls(full) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, entries} ->
        relative = if path == ".", do: name, else: Path.join(path, name)

        case entry(relative, Path.join(full, name)) do
          {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end

  defp entry(path, full) do
    case File.lstat(full) do
      {:ok, %{type: :directory}} ->
        {:ok, %Entry{path: path, kind: :directory, mode: nil, size: 0}}

      {:ok, %{type: :regular, mode: bits, size: size}} ->
        {:ok, %Entry{path: path, kind: :file, mode: mode(bits), size: size}}

      {:ok, _} ->
        {:error, {:unsupported_file, path}}

      error ->
        error
    end
  end

  defp delete_native(root, path) do
    with {:ok, full} <- Files.path(root, path),
         {:ok, stat} <- File.lstat(full) do
      if stat.type == :directory, do: File.rmdir(full), else: File.rm(full)
    end
  end

  defp mode(bits), do: if(Bitwise.band(bits, 0o111) == 0, do: :regular, else: :executable)

  defp absolute("."), do: "/"
  defp absolute(path), do: "/" <> path
end
