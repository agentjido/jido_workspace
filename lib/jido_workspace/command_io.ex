defmodule Jido.Workspace.CommandIO do
  @moduledoc false

  # Workspace owns the table. The provider writes output and, for stdin
  # pipes or TCP services, publishes the transport for another caller. Memory
  # commands collect their result prefix here, including output before stop.
  def open(limit, capture_result?) do
    table = :ets.new(__MODULE__, [:public, :set])
    head = if capture_result?, do: ""
    :ets.insert(table, {:output, limit, 0, "", head})
    table
  end

  def attach_input(table, port) do
    :ets.insert(table, {:input, port})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def attach_connector(table, connector) do
    :ets.insert(table, {:connector, connector})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def connector(table) do
    case :ets.lookup(table, :connector) do
      [{:connector, connector}] -> {:ok, connector}
      [] -> {:error, :service_not_ready}
    end
  end

  def connect({executable, args, env}, port) do
    connection =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:args, args ++ [Integer.to_string(port)]},
          {:env, env}
        ]
      )

    {:ok, connection}
  rescue
    _ in [ArgumentError, ErlangError] -> {:error, :start_failed}
  end

  def input(table, bytes) do
    case :ets.lookup(table, :input) do
      [{:input, port}] ->
        if Port.command(port, bytes, [:nosuspend]), do: :ok, else: {:error, :input_busy}

      [] ->
        {:error, :input_not_ready}
    end
  rescue
    ArgumentError -> {:error, :input_closed}
  end

  def append(table, bytes) do
    [{:output, limit, offset, tail, head}] = :ets.lookup(table, :output)
    count = byte_size(bytes)

    tail =
      if count >= limit do
        :binary.copy(binary_part(bytes, count - limit, limit))
      else
        keep = min(byte_size(tail), limit - count)
        binary_part(tail, byte_size(tail) - keep, keep) <> bytes
      end

    head = append_head(head, bytes, limit)
    :ets.insert(table, {:output, limit, offset + count, tail, head})
    :ok
  rescue
    # A provider can emit late output after the controller closes the table.
    ArgumentError -> :ok
  end

  def result(table) do
    [{:output, limit, count, _, head}] = :ets.lookup(table, :output)
    %{output: head, truncated: count > limit}
  end

  defp append_head(nil, _, _), do: nil
  defp append_head(head, _, limit) when byte_size(head) == limit, do: head

  defp append_head("", bytes, limit) do
    :binary.copy(binary_part(bytes, 0, min(byte_size(bytes), limit)))
  end

  defp append_head(head, bytes, limit) do
    keep = min(byte_size(bytes), limit - byte_size(head))
    head <> binary_part(bytes, 0, keep)
  end

  def close(table) do
    [record] = :ets.lookup(table, :output)
    :ets.delete(table)
    record
  end

  def read(table, offset) when is_reference(table) do
    [record] = :ets.lookup(table, :output)
    slice(record, offset, false)
  end

  def read(record, offset), do: slice(record, offset, true)

  # OTP can retain incoming messages for status and termination reports.
  def redact_status(status) do
    Map.new(status, fn
      {:message, message} -> {:message, redact_message(message)}
      {:log, events} -> {:log, Enum.map(events, &redact_event/1)}
      entry -> entry
    end)
  end

  defp redact_event({:in, message}), do: {:in, redact_message(message)}
  defp redact_event(event), do: event

  defp redact_message({:"$gen_call", from, message}),
    do: {:"$gen_call", from, redact_message(message)}

  defp redact_message({:command_input, id, _}), do: {:command_input, id, :redacted}
  defp redact_message({port, {:data, _}}) when is_port(port), do: {port, {:data, :redacted}}
  defp redact_message(message), do: message

  defp slice({:output, _, next_offset, tail, _}, offset, done?) when offset <= next_offset do
    first = next_offset - byte_size(tail)
    start = max(first, offset)
    bytes = :binary.copy(binary_part(tail, start - first, next_offset - start))

    {:ok,
     %{
       bytes: bytes,
       next_offset: next_offset,
       dropped_bytes: start - offset,
       done?: done?
     }}
  end

  defp slice(_, _, _), do: {:error, :invalid_input}
end
