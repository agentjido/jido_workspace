defmodule Jido.Workspace.ProfileProvider do
  @moduledoc false

  alias Jido.Shell.{CommandRunner, VFS}
  alias Jido.Shell.Error, as: ShellError
  alias Jido.Shell.ShellSession.State
  alias Jido.VFS.Capture
  alias Jido.Workspace
  alias Jido.Workspace.{CommandIO, Discovery, EmbeddedLua, Entry, Lifetime, Policy, Profile}
  alias Jido.Workspace.{InfrastructureRef, Provider, ProviderLease, Sandbox}
  alias Jido.Workspace.SnapshotStore
  alias Jido.Workspace.Sandbox.Files

  @memory_capabilities %{
    provider: :memory,
    isolation: :mediated,
    network: :disabled,
    runtime_limits: %{}
  }
  @memory_stage_group 1_024

  def open(%{provider: :memory} = profile, capture, _) do
    with :ok <- admit(@memory_capabilities, profile.require),
         {:ok, workspace} <- Workspace.open() do
      initialize({:memory, workspace}, capture, @memory_capabilities)
    end
  end

  def open(%{provider: {module, options}} = profile, capture, scope) do
    with {:ok, lease_handle, lease} <- ProviderLease.start(profile.provider, scope) do
      tree_access = if Policy.allows?(profile.policy, :write), do: :read_write, else: :read_only

      settings = %{
        tree_access: tree_access,
        options: options,
        require: profile.require,
        limits: Map.merge(Profile.command_limits(profile), profile.limits)
      }

      case provision(module, lease, settings, capture) do
        {:ok, environment, capabilities} ->
          {:ok, {:custom, module, environment, lease_handle}, capabilities}

        {:error, _} = error ->
          with :ok <- ProviderLease.release(lease_handle), do: error
      end
    end
  end

  def open(profile, capture, _) do
    opts = [
      provider: profile.provider,
      image: profile[:image],
      owner: self(),
      workspace_read_only: not Policy.allows?(profile.policy, :write)
    ]

    opts = Keyword.merge(opts, Map.to_list(Map.take(profile, [:runner])))

    opts =
      if profile[:checkout],
        do: [checkout: profile.checkout, policy: checkout_policy(profile.policy)] ++ opts,
        else: opts

    with {:ok, sandbox} <- Sandbox.open(opts) do
      provider = {:native, sandbox}
      capabilities = Sandbox.capabilities(sandbox)

      capabilities =
        if profile[:service],
          do: Map.put(capabilities, :service_ports, profile.service.ports),
          else: capabilities

      case admit(capabilities, profile.require) do
        :ok -> initialize(provider, capture, capabilities)
        error -> release_failed_open(provider, error)
      end
    else
      {:error, {:sandbox_unavailable, _}} -> {:error, :cleanup_unconfirmed}
      {:error, _} = error -> error
    end
  end

  defp provision(module, lease, settings, capture) do
    result = Provider.call(module, :provision, [lease, settings, capture], :provider_failed)

    with {:ok, environment, report} <- provision_result(result, lease.infrastructure),
         {:ok, capabilities} <- Profile.provider_capabilities(report),
         :ok <- admit(capabilities, Map.put(settings.require, :tree_access, settings.tree_access)) do
      {:ok, environment, Map.put(capabilities, :provider, module)}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {:unsupported_capability, name}} when is_atom(name) ->
        {:error, {:unsupported_capability, name}}

      _ ->
        {:error, :provider_failed}
    end
  end

  defp provision_result({:ok, environment, report}, nil), do: {:ok, environment, report}

  defp provision_result({:ok, environment, report, actual}, reference) when is_map(reference) do
    case InfrastructureRef.parse(actual) do
      {:ok, ^reference} -> {:ok, environment, report}
      _ -> {:error, :infrastructure_mismatch}
    end
  end

  defp provision_result({:ok, _, _}, _), do: {:error, :infrastructure_mismatch}
  defp provision_result({:ok, _, _, _}, _), do: {:error, :infrastructure_mismatch}

  defp provision_result({:error, {:unsupported_capability, name}}, _) when is_atom(name),
    do: {:error, {:unsupported_capability, name}}

  defp provision_result({:error, reason}, reference)
       when is_map(reference) and
              reason in [
                :infrastructure_not_found,
                :infrastructure_unavailable,
                :infrastructure_busy,
                :quiescence_unknown
              ],
       do: {:error, reason}

  defp provision_result(_, _), do: {:error, :provider_failed}

  def confirm_open({:custom, _, _, lease}, deadline), do: ProviderLease.confirm(lease, deadline)
  def confirm_open(_, _), do: :ok

  defp checkout_policy(policy) do
    cond do
      Policy.allows?(policy, :execute) -> :full_access
      Policy.allows?(policy, :write) -> :workspace_write
      true -> :read_only
    end
  end

  def close({:memory, %Workspace.Workspace{lifetime: pid}}) do
    Lifetime.call(pid, :close)
  catch
    :exit, _ -> {:error, :cleanup_unconfirmed}
  end

  def close({:native, sandbox}), do: Sandbox.destroy(sandbox)
  def close({:custom, _, _, lease}), do: ProviderLease.release(lease)

  def file({kind, _} = provider, :write, [path, bytes, {:revision, revision}])
      when kind in [:memory, :native] do
    file(provider, :write, [path, bytes, &Provider.check_revision(&1, revision)])
  end

  def file({:memory, workspace}, operation, args) do
    case Lifetime.call(workspace.lifetime, {:working_file, operation, args}) do
      {:ok, entries} when operation == :list ->
        [path | _] = args

        entries =
          entries
          |> Enum.map(fn entry ->
            %Entry{
              path: relative_entry(path, entry.name),
              kind: if(is_struct(entry, Jido.VFS.Stat.Dir), do: :directory, else: :file),
              size: entry.size
            }
          end)
          |> Enum.sort_by(& &1.path)

        {:ok, entries}

      result ->
        result
    end
  catch
    :exit, _ when operation in [:read, :list] -> {:error, :operation_failed}
    :exit, _ -> {:error, :quiescence_unknown}
  end

  def file({:native, sandbox}, :list, [path]) do
    with {:ok, entries, _} <- list_native(sandbox, path, :infinity), do: {:ok, entries}
  end

  def file({:native, sandbox}, :write, [path, bytes]),
    do: Sandbox.write_checked(sandbox, path, bytes, :any)

  def file({:native, sandbox}, :write, [path, bytes, check]),
    do: Sandbox.write_checked(sandbox, path, bytes, check)

  def file({:native, sandbox}, operation, args)
      when operation in [:read, :mkdir, :move, :delete],
      do: apply(Sandbox, operation, [sandbox | args])

  def file({:custom, _, _, _} = provider, operation, args) do
    request = file_request(operation, args)
    read? = operation in [:read, :list, :upload_target]
    failure = if read?, do: :operation_failed, else: :quiescence_unknown

    case custom_call(provider, :file, [request], failure) do
      :ok when operation not in [:read, :list] ->
        :ok

      {:ok, entries} when operation == :list and is_list(entries) ->
        if Enum.all?(entries, &match?(%Entry{path: path} when is_binary(path), &1)),
          do: {:ok, Enum.sort_by(entries, & &1.path)},
          else: {:error, failure}

      {:ok, bytes} when operation == :read and is_binary(bytes) ->
        check_read_size(request, bytes)

      {:error, {:unsupported_capability, key}} when is_atom(key) ->
        {:error, {:unsupported_capability, key}}

      {:error, reason} when read? and is_atom(reason) ->
        {:error, reason}

      {:error, reason}
      when reason in [
             :not_found,
             :not_directory,
             :is_directory,
             :already_exists,
             :directory_not_empty,
             :stale_revision,
             :lease_revoked,
             :invalid_input
           ] ->
        {:error, reason}

      _ ->
        {:error, failure}
    end
  end

  defp file_request(:write, [path, bytes]), do: {:write, path, bytes, :any}
  defp file_request(:read, [path]), do: {:read, path, :infinity}
  defp file_request(:list, [path]), do: {:list, path, :infinity}
  defp file_request(:upload_target, [path]), do: {:check_write, path}
  defp file_request(operation, args), do: List.to_tuple([operation | args])

  defp check_read_size({:read, _, limit}, bytes)
       when is_integer(limit) and byte_size(bytes) > limit,
       do: {:error, :discovery_byte_limit}

  defp check_read_size({:read, _, _, limit}, bytes) when byte_size(bytes) > limit,
    do: {:error, :operation_failed}

  defp check_read_size(_, bytes), do: {:ok, bytes}

  def begin_upload({:native, sandbox}, path) do
    with :ok <- Sandbox.upload(sandbox, {:begin, path}), do: {:ok, nil}
  end

  def begin_upload(provider, path) do
    with :ok <- file(provider, :upload_target, [path]), do: {:ok, {[], [], 0}}
  end

  def append_upload({:native, sandbox}, nil, bytes) do
    with :ok <- Sandbox.upload(sandbox, {:chunk, bytes}), do: {:ok, nil}
  end

  def append_upload(_, stage, ""), do: {:ok, stage}

  def append_upload(_, {blocks, pending, count}, bytes) do
    chunk =
      if :binary.referenced_byte_size(bytes) > byte_size(bytes),
        do: :binary.copy(bytes),
        else: bytes

    pending = [chunk | pending]

    if count + 1 == @memory_stage_group do
      {:ok, {[pack_chunks(pending) | blocks], [], 0}}
    else
      {:ok, {blocks, pending, count + 1}}
    end
  end

  def commit_upload({:native, sandbox}, _, nil), do: Sandbox.upload(sandbox, :commit)

  def commit_upload(provider, path, {blocks, pending, _}) do
    bytes = IO.iodata_to_binary([Enum.reverse(blocks), Enum.reverse(pending)])
    file(provider, :write, [path, bytes])
  end

  def abort_upload({:native, sandbox}), do: Sandbox.upload(sandbox, :abort)
  def abort_upload(_), do: :ok

  defp pack_chunks(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  def find(provider, path, needle, settings) do
    with {:ok, path} <- discovery_root(provider, path) do
      Discovery.find(
        path,
        needle,
        settings,
        &discovery_list(provider, &1, &2),
        &file(provider, :read, [&1, &2])
      )
    end
  end

  defp discovery_root({:native, sandbox}, path) do
    with :ok <- check_checkout(sandbox),
         {:ok, full} <- Files.path(sandbox.root, path),
         do: {:ok, Path.relative_to(full, sandbox.root)}
  end

  defp discovery_root(_, path), do: {:ok, path}

  defp discovery_list({:native, sandbox}, path, limit), do: list_native(sandbox, path, limit)

  defp discovery_list(provider, path, limit) do
    with {:ok, entries} <- file(provider, :list, [path, limit]),
         count = length(entries),
         true <- count <= limit do
      {:ok, entries, count}
    else
      false -> {:error, :discovery_entry_limit}
      error -> error
    end
  end

  def capture({:memory, workspace}) do
    with {:ok, capture, _} <- Workspace.capture(workspace), do: {:ok, capture}
  end

  def capture({:native, sandbox}) do
    with :ok <- check_checkout(sandbox),
         {:ok, entries} <- Files.capture(sandbox.root, ".", true, SnapshotStore.capture_budget()),
         {:ok, entries} <- portable_entries(entries) do
      {:ok, %Capture{entries: entries}}
    end
  end

  def capture({:custom, _, _, _} = provider) do
    {entries, bytes} = SnapshotStore.capture_budget()

    case custom_call(provider, :capture, [%{entries: entries, bytes: bytes}], :operation_failed) do
      {:ok, %Capture{entries: entries} = tree} when is_map(entries) -> {:ok, tree}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :operation_failed}
    end
  end

  def admit_stdin(_, :closed), do: :ok
  def admit_stdin(%{stdin: :pipe}, :pipe), do: :ok
  def admit_stdin(_, :pipe), do: {:error, {:unsupported_capability, :stdin}}

  def admit_recovery(%{infrastructure: _, provider: {module, _}}) do
    if function_exported?(module, :recover_command, 4),
      do: :ok,
      else: {:error, {:unsupported_capability, :command_recovery}}
  end

  def admit_recovery(_), do: {:error, {:unsupported_capability, :command_recovery}}

  def admit_command_reference(profile, infrastructure, %{command: reference}) do
    with :ok <- admit_recovery(profile) do
      if reference.infrastructure == infrastructure,
        do: :ok,
        else: {:error, :infrastructure_mismatch}
    end
  end

  def admit_command_reference(_, _, _), do: :ok

  def recover_command(%{provider: {module, options}}, reference, action, timeout) do
    task =
      Task.Supervisor.async_nolink(Jido.Workspace.ProfileSession.Tasks, fn ->
        Provider.call(
          module,
          :recover_command,
          [reference, action, timeout, options],
          :quiescence_unknown
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, :running}} when action != :stop ->
        {:ok, %{status: :running, exit_status: nil}}

      {:ok, {:ok, {:exited, status}}} when is_integer(status) and status >= 0 ->
        {:ok, %{status: :exited, exit_status: status}}

      {:ok, {:error, :command_not_found}} ->
        {:error, :command_not_found}

      _ ->
        {:error, :quiescence_unknown}
    end
  end

  def run({:memory, workspace} = provider, argv, opts) do
    cwd = absolute(opts.cwd)

    with {:ok, %Workspace.Info{id: namespace}} <- Workspace.info(workspace),
         {:ok, %Jido.VFS.Stat.Dir{}} <- VFS.stat(namespace, cwd) do
      stop = opts.stop

      try do
        check_stop(opts)

        run_virtual(provider, {namespace, cwd}, argv, opts)
      catch
        {^stop, status} -> virtual_exit(opts, nil, status)
      end
    else
      {:ok, _} -> {:error, :not_directory}
      {:error, _} = error -> error
    end
  end

  def run({:native, sandbox}, [command | args], opts) do
    with :ok <- check_checkout(sandbox),
         {:ok, cwd} <- Files.path(sandbox.root, opts.cwd),
         {:ok, %{type: :directory}} <- File.stat(cwd) do
      Sandbox.exec(
        sandbox,
        command,
        args,
        [dir: opts.cwd, timeout: opts.timeout_ms, output_limit: opts.output_limit],
        Map.take(opts, [:stop, :io_buffer, :stdin, :connector])
      )
      |> native_result()
    else
      {:ok, _} -> {:error, :not_directory}
      error -> error
    end
  end

  def run({:custom, _, _, _} = provider, argv, opts) do
    request =
      opts
      |> Map.take([:id, :cwd, :timeout_ms, :output_limit, :command])
      |> Map.merge(%{
        argv: argv,
        emit: &CommandIO.append(opts.io_buffer, &1),
        stop_reason: fn -> stop_reason(opts) end
      })

    case stop_reason(opts) do
      nil ->
        case custom_call(provider, :run, [request], :quiescence_unknown) do
          {:ok, {:exited, status}} when is_integer(status) and status >= 0 ->
            virtual_exit(opts, status)

          {:ok, status} when status in [:cancelled, :timed_out] ->
            virtual_exit(opts, nil, status)

          {:error, reason} = error when reason in [:start_failed, :lease_revoked] ->
            error

          {:error, :command_reference_used} = error when is_map_key(opts, :command) ->
            error

          _ ->
            {:error, :quiescence_unknown}
        end

      stopped ->
        virtual_exit(opts, nil, stopped)
    end
  end

  defp custom_call({:custom, module, environment, lease}, callback, args, failure) do
    if ProviderLease.available?(lease),
      do: Provider.call(module, callback, [environment | args], failure),
      else: {:error, failure}
  end

  defp check_checkout(sandbox), do: Files.check_checkout(sandbox.root, sandbox.checkout_key)

  defp run_virtual(provider, _, ["lua" | args], opts) do
    case EmbeddedLua.run(args, opts, &file(provider, :read, [&1, &2])) do
      {:ok, files} ->
        check_stop(opts)
        publish_lua(provider, files, opts)

      {:stopped, status} ->
        virtual_exit(opts, nil, status)

      :failed ->
        check_stop(opts)
        virtual_exit(opts, 1)

      {:error, _} = error ->
        check_stop(opts)
        error
    end
  end

  defp run_virtual(_, {namespace, cwd}, argv, opts) do
    with {:ok, shell} <- State.new(%{id: namespace, workspace_id: namespace, cwd: cwd}) do
      result =
        CommandRunner.execute_argv(shell, argv, fn chunk ->
          collect(chunk, opts)
          check_stop(opts)
        end)

      check_stop(opts)
      virtual_result(result, opts)
    end
  end

  defp publish_lua(_, [], opts), do: virtual_exit(opts, 0)

  defp publish_lua(provider, files, opts) do
    case file(provider, :write_many, [files]) do
      :ok ->
        virtual_exit(opts, 0)

      {:error, reason} when reason in [:closed, :quiescence_unknown] ->
        {:error, :quiescence_unknown}

      {:error, _} ->
        CommandIO.append(opts.io_buffer, "Lua could not publish the staged files\n")
        virtual_exit(opts, 1)
    end
  end

  defp check_stop(opts) do
    if reason = stop_reason(opts), do: throw({opts.stop, reason})
  end

  defp stop_reason(opts) do
    cond do
      :atomics.get(opts.stop, 1) == 1 -> :cancelled
      System.monotonic_time(:millisecond) >= opts.deadline -> :timed_out
      true -> nil
    end
  end

  defp virtual_result({:ok, _}, opts), do: virtual_exit(opts, 0)

  defp virtual_result({:error, %ShellError{code: {kind, code}, message: message}}, opts)
       when kind in [:validation, :command] or
              (kind == :vfs and code not in [:no_mount, :unknown]) do
    collect({:output_stderr, [message, "\n"]}, opts)
    virtual_exit(opts, 1)
  end

  defp virtual_result({:error, _} = error, _opts), do: error

  defp virtual_exit(opts, exit_status, status \\ :exited) do
    {:ok,
     Map.merge(CommandIO.result(opts.io_buffer), %{status: status, exit_status: exit_status})}
  end

  defp native_result({:error, {:start_failed, _}}), do: {:error, :start_failed}
  defp native_result({:error, :executable_not_found}), do: {:error, :start_failed}

  defp native_result(result) do
    case result do
      {:ok, %{status: :exited, exit_status: exit_status}} when is_integer(exit_status) ->
        result

      {:ok, %{status: status} = execution} when status in [:cancelled, :timed_out] ->
        {:ok, %{execution | exit_status: nil}}

      _ ->
        {:error, :quiescence_unknown}
    end
  end

  defp initialize(provider, capture, capabilities) do
    case restore(provider, capture) do
      :ok -> {:ok, provider, capabilities}
      error -> release_failed_open(provider, error)
    end
  end

  def release_failed_open(provider, error) do
    case close(provider) do
      :ok -> error
      _ -> {:error, :cleanup_unconfirmed}
    end
  end

  defp admit(capabilities, requirements) when is_map(capabilities) do
    Enum.find_value(requirements, :ok, fn {key, value} ->
      unless meets_requirement?(key, Map.get(capabilities, key), value),
        do: {:error, {:unsupported_capability, key}}
    end)
  end

  defp admit(_, _), do: {:error, :quiescence_unknown}

  defp meets_requirement?(:runtime_limits, limits, required) when is_map(limits) do
    Enum.all?(required, fn {key, maximum} ->
      case Map.fetch(limits, key) do
        {:ok, value} when is_integer(value) -> value <= maximum
        _ -> false
      end
    end)
  end

  defp meets_requirement?(_, actual, required), do: actual == required

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

      {path, _}, _ ->
        {:halt, {:error, {:unsupported_file, path}}}
    end)
  end

  defp collect({channel, chunk}, opts) when channel in [:output, :output_stderr] do
    CommandIO.append(opts.io_buffer, IO.iodata_to_binary(chunk))
  end

  defp collect(_, _), do: :ok

  defp list_native(sandbox, path, limit) do
    with :ok <- check_checkout(sandbox),
         {:ok, full} <- Files.path(sandbox.root, path, :literal),
         {:ok, names} <- File.ls(full),
         count = length(names),
         true <- limit == :infinity or count <= limit,
         {:ok, entries} <- native_entries(names, path, full, limit != :infinity) do
      {:ok, entries, count}
    else
      false -> {:error, :discovery_entry_limit}
      error -> error
    end
  end

  defp native_entries(names, path, full, skip_special?) do
    names
    |> Enum.sort(:desc)
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, entries} ->
      relative = relative_entry(path, name)

      case entry(relative, Path.join(full, name)) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, {:unsupported_file, _}} when skip_special? -> {:cont, {:ok, entries}}
        error -> {:halt, error}
      end
    end)
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

  defp mode(bits), do: if(Bitwise.band(bits, 0o111) == 0, do: :regular, else: :executable)

  defp relative_entry(".", name), do: name
  defp relative_entry(path, name), do: Path.join(path, name)

  defp absolute("."), do: "/"
  defp absolute(path), do: "/" <> path
end
