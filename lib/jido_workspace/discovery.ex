defmodule Jido.Workspace.Discovery do
  @moduledoc false

  alias Jido.Workspace.Schemas

  @defaults %{
    hidden: false,
    binary: false,
    exclude: [],
    max_entries: 10_000,
    max_bytes: 8 * 1024 * 1024
  }

  def schema do
    Zoi.map(
      %{
        hidden: Zoi.boolean() |> Zoi.optional(),
        binary: Zoi.boolean() |> Zoi.optional(),
        exclude: Zoi.array(Zoi.string(), max_length: 128) |> Zoi.optional(),
        max_entries: Zoi.integer() |> Zoi.min(1) |> Zoi.max(100_000) |> Zoi.optional(),
        max_bytes: Zoi.integer() |> Zoi.min(1) |> Zoi.max(64 * 1024 * 1024) |> Zoi.optional()
      },
      unrecognized_keys: :error
    )
    |> Zoi.default(%{})
  end

  def validate(settings) do
    if Enum.all?(Map.get(settings, :exclude, []), &(&1 != "." and Schemas.relative_path?(&1))),
      do: :ok,
      else: :error
  end

  def find(path, needle, settings, list, read) do
    settings = Map.merge(@defaults, settings)
    query = %{needle: needle, settings: settings, list: list, read: read}
    budget = %{entries: settings.max_entries, bytes: settings.max_bytes, matches: []}

    if visible?(path, settings) do
      case walk(path, budget, query) do
        {:ok, result} -> {:ok, Enum.sort_by(result.matches, & &1.path)}
        error -> error
      end
    else
      {:ok, []}
    end
  end

  defp walk(path, budget, query) do
    with {:ok, entries, count} <- query.list.(path, budget.entries) do
      budget = %{budget | entries: budget.entries - count}

      Enum.reduce_while(entries, {:ok, budget}, fn entry, {:ok, budget} ->
        result =
          if visible?(entry.path, query.settings),
            do: visit(entry, budget, query),
            else: {:ok, budget}

        case result do
          {:ok, _} -> {:cont, result}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp visit(%{kind: :directory, path: path}, budget, query), do: walk(path, budget, query)

  defp visit(entry, budget, %{needle: nil}),
    do: {:ok, %{budget | matches: [entry | budget.matches]}}

  defp visit(entry, budget, query) do
    with {:ok, bytes} <- query.read.(entry.path, budget.bytes) do
      budget = %{budget | bytes: budget.bytes - byte_size(bytes)}

      if (query.settings.binary or text?(bytes)) and
           :binary.match(bytes, query.needle) != :nomatch,
         do: {:ok, %{budget | matches: [entry | budget.matches]}},
         else: {:ok, budget}
    end
  end

  defp visible?(".", _), do: true

  defp visible?(path, settings) do
    Schemas.relative_path?(path) and
      (settings.hidden or not Enum.any?(Path.split(path), &String.starts_with?(&1, "."))) and
      not Enum.any?(settings.exclude, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  defp text?(bytes), do: :binary.match(bytes, <<0>>) == :nomatch and String.valid?(bytes)
end
