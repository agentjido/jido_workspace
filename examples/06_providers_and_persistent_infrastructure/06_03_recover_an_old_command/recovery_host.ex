defmodule Jido.Workspace.Examples.RecoveryHost do
  @moduledoc false
  use GenServer

  alias Jido.Workspace.Examples.{MachinePool, MachineProvider, RecoveryProvider}
  alias Jido.Workspace.Sandbox.Files

  @script """
  printf 'started\n' >> "$1/starts"
  while [ ! -f "$1/finish" ]; do sleep 0.05; done
  printf 'complete\n' > "$1/report"
  """

  def start_link(args), do: GenServer.start_link(__MODULE__, args)
  def options(host), do: GenServer.call(host, :options)

  def current_writer(host, machine), do: GenServer.call(host, {:current_writer, machine})

  def revoke_writer(host, machine, id),
    do: GenServer.call(host, {:revoke_writer, %{infrastructure: machine, id: id}})

  def begin_maintenance(host, machine, id) when is_binary(id) and byte_size(id) in 1..128,
    do: GenServer.call(host, {:begin_maintenance, machine, id})

  def run_maintenance(host, machine, id, [_ | _] = argv),
    do: GenServer.call(host, {:run_maintenance, machine, id, argv})

  def end_maintenance(host, machine, id),
    do: GenServer.call(host, {:end_maintenance, machine, id})

  def set_transport(host, status) when status in [:online, :offline],
    do: GenServer.call(host, {:transport, status})

  def job_path(tree, ref), do: Path.join(tree, job_directory(ref))

  @impl true
  def init({pool, machine}) do
    token = :crypto.strong_rand_bytes(32)
    {:ok, listener} = listen(0, token)
    {:ok, port} = :inet.port(listener)

    {:ok,
     %{
       options: %{port: port, token: token},
       listener: listener,
       pool: pool,
       machine: machine,
       tree: MachinePool.tree(pool, machine),
       writer: nil,
       revoked: MapSet.new(),
       ended_maintenance: MapSet.new(),
       commands: %{}
     }}
  end

  @impl true
  def handle_call(:options, _, state), do: {:reply, state.options, state}

  def handle_call({:transport, :offline}, _, %{listener: listener} = state)
      when not is_nil(listener) do
    :ok = :gen_tcp.close(listener)
    {:reply, :ok, %{state | listener: nil}}
  end

  def handle_call({:transport, :online}, _, %{listener: nil} = state) do
    case listen(state.options.port, state.options.token) do
      {:ok, listener} -> {:reply, :ok, %{state | listener: listener}}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:transport, _}, _, state), do: {:reply, :ok, state}

  def handle_call(
        {:current_writer, machine},
        _,
        %{machine: machine, writer: %{kind: :workspace, id: id}} = state
      ),
      do: {:reply, {:ok, id}, state}

  def handle_call({:current_writer, _}, _, state), do: {:reply, {:error, :not_found}, state}

  def handle_call({:acquire, %{id: id, infrastructure: machine}, access}, _, state) do
    cond do
      machine != state.machine ->
        {:reply, {:error, :infrastructure_not_found}, state}

      state.writer != nil ->
        {:reply, {:error, :infrastructure_busy}, state}

      MapSet.member?(state.revoked, id) ->
        {:reply, {:error, :quiescence_unknown}, state}

      machine_running?(state) ->
        {:reply, :ok, %{state | writer: %{kind: :workspace, id: id, access: access}}}

      true ->
        {:reply, {:error, :infrastructure_unavailable}, state}
    end
  end

  def handle_call(
        {:revoke_writer, %{infrastructure: machine, id: id}},
        _,
        %{machine: machine} = state
      ),
      do: revoke(state, id)

  def handle_call({:revoke_writer, _}, _, state),
    do: {:reply, {:error, :infrastructure_not_found}, state}

  def handle_call({:release, %{infrastructure: machine, id: id}}, _, %{machine: machine} = state),
    do: revoke(state, id)

  def handle_call({:release, _}, _, state), do: {:reply, :ok, state}

  def handle_call({:begin_maintenance, machine, id}, _, %{machine: machine} = state) do
    case state.writer do
      %{kind: :maintenance, id: ^id} = console ->
        {:reply, console_details(state.pool, console), state}

      nil ->
        start_console(state, id)

      _ ->
        {:reply, {:error, :infrastructure_busy}, state}
    end
  end

  def handle_call({:end_maintenance, machine, id}, _, %{machine: machine} = state) do
    case state.writer do
      %{kind: :maintenance, id: ^id} = console ->
        console = %{console | returning: true}
        state = %{state | writer: console}
        finish_console(state, console)

      _ ->
        result =
          if MapSet.member?(state.ended_maintenance, id),
            do: :ok,
            else: {:error, :maintenance_not_found}

        {:reply, result, state}
    end
  end

  def handle_call({action, _, _}, _, state) when action in [:begin_maintenance, :end_maintenance],
    do: {:reply, {:error, :infrastructure_not_found}, state}

  def handle_call(
        {:run_maintenance, machine, id, argv},
        _,
        %{machine: machine, writer: %{kind: :maintenance, id: id, returning: false} = console} =
          state
      ) do
    {:reply, run_console(state.pool, console, argv), state}
  end

  def handle_call({:run_maintenance, _, _, _}, _, state),
    do: {:reply, {:error, :maintenance_closed}, state}

  def handle_call({:file, lease, request}, _, state) do
    response =
      with :ok <- active_lease(state, lease), do: file(state.tree, state.writer.access, request)

    {:reply, response, state}
  end

  def handle_call({:capture, lease, budget}, _, state) do
    response =
      with :ok <- active_lease(state, lease),
           :ok <- confirm_writers_stopped(state, lease.id),
           {:ok, _} = captured <- MachineProvider.capture_tree(state.tree, budget),
           true <- :erlang.external_size(captured) <= RecoveryProvider.packet_limit() do
        captured
      else
        false -> {:error, :snapshot_too_large}
        error -> error
      end

    {:reply, response, state}
  end

  def handle_call({:launch, lease, ref, drop_reply?}, _, state) do
    with :ok <- active_lease(state, lease),
         :read_write <- state.writer.access,
         true <- ref.infrastructure == state.machine,
         false <- Map.has_key?(state.commands, ref) do
      job = %{lease: lease.id, name: job_name(state.pool, ref), container: nil}
      state = put_in(state.commands[ref], job)

      case launch(state, ref, job) do
        {:ok, container} ->
          state = put_in(state.commands[ref].container, container)
          {:reply, if(drop_reply?, do: :drop_reply, else: :ok), state}

        error ->
          {:reply, error, state}
      end
    else
      true -> {:reply, {:error, :command_reference_used}, state}
      {:error, :lease_revoked} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :start_failed}, state}
    end
  end

  def handle_call({action, %{infrastructure: machine} = ref}, _, %{machine: machine} = state)
      when action in [:inspect, :stop] do
    response =
      case Map.fetch(state.commands, ref) do
        {:ok, job} -> recover(state.pool, job, action)
        :error -> {:error, :command_not_found}
      end

    {:reply, response, state}
  end

  def handle_call(_, _, state), do: {:reply, {:error, :quiescence_unknown}, state}

  defp revoke(state, id) do
    state = %{state | revoked: MapSet.put(state.revoked, id)}

    case state.writer do
      %{kind: :workspace, id: ^id} ->
        case confirm_writers_stopped(state, id) do
          :ok -> {:reply, :ok, %{state | writer: nil}}
          {:error, :quiescence_unknown} -> {:reply, {:error, :cleanup_unconfirmed}, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  defp confirm_writers_stopped(state, id) do
    settled? =
      Enum.all?(state.commands, fn
        {_, %{lease: ^id} = job} -> exited?(state.pool, job)
        _ -> true
      end)

    if settled?, do: :ok, else: {:error, :quiescence_unknown}
  end

  defp active_lease(%{writer: %{kind: :workspace, id: id}, machine: machine} = state, %{
         id: id,
         infrastructure: machine
       }) do
    if MapSet.member?(state.revoked, id), do: {:error, :lease_revoked}, else: :ok
  end

  defp active_lease(_, _), do: {:error, :lease_revoked}

  defp file(tree, _, {:read, path, :infinity}), do: Files.read(tree, path)
  defp file(tree, _, {:read, path, limit}), do: Files.read(tree, path, limit)

  defp file(tree, :read_write, {:write, path, bytes, :any}),
    do: Files.write_checked(tree, path, bytes, :any)

  defp file(_, _, _), do: {:error, :unsupported_capability}

  defp start_console(state, id) do
    cond do
      MapSet.member?(state.ended_maintenance, id) ->
        {:reply, {:error, :maintenance_closed}, state}

      machine_running?(state) ->
        name = "jido-example-console-" <> state.pool.tag <> "-" <> digest(id)
        console = %{kind: :maintenance, id: id, name: name, returning: false, removal_id: nil}
        state = %{state | writer: console}
        launch_container(state, name, "/bin/sleep", ["2147483647"])
        {:reply, console_details(state.pool, console), state}

      true ->
        {:reply, {:error, :infrastructure_unavailable}, state}
    end
  end

  defp machine_running?(state),
    do: match?({:ok, %{running: true}}, MachinePool.inspect_machine(state.pool, state.machine))

  defp console_details(pool, %{id: id, returning: false} = console) do
    case inspect_job(pool, console) do
      {:ok, container, :running} -> {:ok, %{id: id, container: container}}
      _ -> {:error, :quiescence_unknown}
    end
  end

  defp console_details(_, _), do: {:error, :cleanup_unconfirmed}

  defp run_console(pool, console, argv) do
    with true <- Enum.all?(argv, &(is_binary(&1) and not String.contains?(&1, <<0>>))),
         {:ok, container, :running} <- inspect_job(pool, console),
         {_, 0} <-
           MachinePool.docker(pool, [
             "exec",
             "--detach",
             "--workdir",
             "/workspace",
             container | argv
           ]) do
      :ok
    else
      false -> {:error, :invalid_input}
      _ -> {:error, :quiescence_unknown}
    end
  end

  defp finish_console(state, %{removal_id: nil} = console) do
    case inspect_job(state.pool, console) do
      {:ok, container, {:exited, _}} -> finish_console(state, %{console | removal_id: container})
      _ -> {:reply, {:error, :cleanup_unconfirmed}, state}
    end
  end

  defp finish_console(state, %{id: id, removal_id: container} = console) do
    if remove_console(state.pool, container) do
      ended = MapSet.put(state.ended_maintenance, id)
      {:reply, :ok, %{state | writer: nil, ended_maintenance: ended}}
    else
      {:reply, {:error, :cleanup_unconfirmed}, %{state | writer: console}}
    end
  end

  defp remove_console(pool, container) do
    case MachinePool.docker(pool, ["rm", container]) do
      {_, 0} ->
        true

      _ ->
        # A lost removal reply still needs a successful absence check.
        case MachinePool.docker(pool, ["ps", "--all", "--quiet", "--filter", "id=" <> container]) do
          {output, 0} -> String.trim(output) == ""
          _ -> false
        end
    end
  end

  defp launch(state, ref, job) do
    directory = job_directory(ref)
    workspace = "/workspace/" <> directory

    with :ok <- File.mkdir_p(job_path(state.tree, ref)),
         {_, 0} <-
           launch_container(state, job.name, "/bin/sh", [
             "-eu",
             "-c",
             @script,
             "report",
             workspace
           ]),
         {:ok, container, _} <- inspect_job(state.pool, job) do
      {:ok, container}
    else
      _ -> {:error, :quiescence_unknown}
    end
  end

  defp launch_container(state, name, executable, args) do
    MachinePool.docker(state.pool, [
      "run",
      "--detach",
      "--pull",
      "never",
      "--name",
      name,
      "--label",
      MachinePool.scope(state.pool),
      "--network",
      "none",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      "32",
      "--memory",
      "64m",
      "--log-driver",
      "none",
      "--mount",
      "type=bind,source=" <> state.tree <> ",target=/workspace,bind-recursive=disabled",
      "--entrypoint",
      executable,
      state.pool.image
      | args
    ])
  end

  defp exited?(pool, job), do: match?({:ok, _, {:exited, _}}, inspect_job(pool, job))

  defp recover(pool, job, action) do
    case inspect_job(pool, job) do
      {:ok, id, :running} when action == :stop ->
        MachinePool.docker(pool, ["kill", id])

        case inspect_job(pool, job) do
          {:ok, ^id, {:exited, _} = outcome} -> {:ok, outcome}
          _ -> {:error, :quiescence_unknown}
        end

      {:ok, _, outcome} ->
        {:ok, outcome}

      error ->
        error
    end
  end

  defp inspect_job(pool, job) do
    [label, tag] = String.split(MachinePool.scope(pool), "=", parts: 2)
    format = ~s({{.Id}} {{.State.Status}} {{.State.ExitCode}} {{index .Config.Labels "#{label}"}})

    with {output, 0} <-
           MachinePool.docker(pool, [
             "inspect",
             "--type",
             "container",
             "--format",
             format,
             Map.get(job, :container) || job.name
           ]) do
      case String.split(output) do
        [id, "running", _, ^tag] -> {:ok, id, :running}
        [id, "exited", status, ^tag] -> {:ok, id, {:exited, String.to_integer(status)}}
        _ -> {:error, :quiescence_unknown}
      end
    else
      _ -> {:error, :quiescence_unknown}
    end
  end

  defp job_directory(ref), do: "run-" <> digest(ref.command_id)
  defp job_name(pool, ref), do: "jido-example-job-" <> pool.tag <> "-" <> digest(ref.command_id)
  defp digest(id), do: Base.encode16(:crypto.hash(:sha256, id), case: :lower)

  defp listen(port, token) do
    options = [{:ip, {127, 0, 0, 1}}, {:reuseaddr, true} | RecoveryProvider.socket_options()]

    with {:ok, listener} <- :gen_tcp.listen(port, options) do
      host = self()
      spawn_link(fn -> accept(listener, host, token) end)
      {:ok, listener}
    end
  end

  defp accept(listener, host, token) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        reply(socket, host, token)
        :gen_tcp.close(socket)
        accept(listener, host, token)

      {:error, :closed} ->
        :ok
    end
  end

  defp reply(socket, host, token) do
    with {:ok, packet} <- :gen_tcp.recv(socket, 0, 1_000),
         {^token, request} <- :erlang.binary_to_term(packet, [:safe]),
         true <- workspace_request?(request),
         response when response != :drop_reply <- GenServer.call(host, request, 20_000) do
      :gen_tcp.send(socket, :erlang.term_to_binary(response))
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  defp workspace_request?(request) when is_tuple(request) and tuple_size(request) > 0,
    do: elem(request, 0) in [:acquire, :release, :file, :capture, :launch, :inspect, :stop]

  defp workspace_request?(_), do: false
end
