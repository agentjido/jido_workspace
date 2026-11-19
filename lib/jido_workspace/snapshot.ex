defmodule Jido.Workspace.Snapshot do
  @moduledoc "A durable reference to a verified file tree in a host-configured store."

  @schema Zoi.map(
            %{
              kind: Zoi.literal("snapshot"),
              format: Zoi.literal(1),
              store: Zoi.string() |> Zoi.regex(~r/\A[A-Za-z0-9_-]{1,128}\z/),
              digest: Zoi.string() |> Zoi.regex(~r/\A[a-f0-9]{64}\z/)
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @type t :: %{kind: String.t(), format: 1, store: String.t(), digest: String.t()}

  @doc "Returns the schema for the durable reference."
  def schema, do: @schema

  @doc "Builds a reference from its store and digest."
  def new(store, digest), do: parse(%{kind: "snapshot", format: 1, store: store, digest: digest})

  @doc "Validates a reference, including one decoded from JSON."
  def parse(value), do: Zoi.parse(@schema, value)
end
