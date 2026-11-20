defmodule Jido.Workspace.Examples.RecoveryProvider do
  @moduledoc false
  @behaviour Jido.Workspace.Provider

  @packet_limit 1_114_112
  @socket_options [:binary, active: false, packet: 4, packet_size: @packet_limit]

  @impl true
  def provision(lease, %{options: options, tree_access: access}, nil) do
    identity = Map.take(lease, [:id, :infrastructure])

    with :ok <- request(options, {:acquire, identity, access}, 5_000) do
      {:ok, {options, identity}, %{tree_access: access, network: :disabled}, lease.infrastructure}
    end
  end

  @impl true
  def file({options, lease}, operation), do: request(options, {:file, lease, operation}, 5_000)

  @impl true
  def capture({options, lease}, budget), do: request(options, {:capture, lease, budget}, 5_000)

  @impl true
  def release(lease, options) do
    request(options, {:release, Map.take(lease, [:id, :infrastructure])}, 5_000)
  end

  @impl true
  def run({options, lease}, %{argv: ["write-report"], cwd: ".", command: ref} = command) do
    with :ok <- request(options, {:launch, lease, ref, options[:lose_reply] == true}, 5_000) do
      wait_for_run(options, ref, command)
    end
  end

  def run(_, _), do: {:error, :start_failed}

  defp wait_for_run(options, ref, command) do
    case command.stop_reason.() do
      nil ->
        case recover_command(ref, :wait, 500, options) do
          {:ok, :running} -> wait_for_run(options, ref, command)
          result -> result
        end

      reason ->
        with {:ok, {:exited, _}} <- recover_command(ref, :stop, 1_000, options),
             do: {:ok, reason}
    end
  end

  @impl true
  def recover_command(ref, :wait, timeout, options) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(options, ref, deadline)
  end

  def recover_command(ref, action, timeout, options) do
    request(options, {action, ref}, timeout)
  end

  defp wait(options, ref, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case request(options, {:inspect, ref}, max(1, remaining)) do
      {:ok, :running} when remaining > 100 ->
        Process.sleep(25)
        wait(options, ref, deadline)

      result ->
        result
    end
  end

  def socket_options, do: @socket_options
  def packet_limit, do: @packet_limit

  defp request(options, operation, timeout) do
    with {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, options.port, @socket_options, timeout) do
      try do
        with :ok <- :gen_tcp.send(socket, :erlang.term_to_binary({options.token, operation})),
             {:ok, reply} <- :gen_tcp.recv(socket, 0, timeout) do
          :erlang.binary_to_term(reply, [:safe])
        else
          _ -> {:error, :quiescence_unknown}
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> {:error, :quiescence_unknown}
    end
  end
end
