defmodule Jido.Workspace.CommandRef do
  @moduledoc "A durable identity for a command on host-managed infrastructure."

  alias Jido.Workspace.InfrastructureRef

  @schema Zoi.map(
            %{
              kind: Zoi.literal("command"),
              format: Zoi.literal(1),
              infrastructure: InfrastructureRef.schema(),
              command_id: Jido.Workspace.Schemas.durable_id_schema()
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @type t :: %{
          kind: String.t(),
          format: 1,
          infrastructure: InfrastructureRef.t(),
          command_id: String.t()
        }

  @doc "Returns the schema for the durable reference."
  def schema, do: @schema

  @doc "Builds a reference from a resource reference and provider command ID."
  def new(infrastructure, command_id),
    do:
      parse(%{kind: "command", format: 1, infrastructure: infrastructure, command_id: command_id})

  @doc "Validates a reference, including one decoded from JSON."
  def parse(value), do: Zoi.parse(@schema, value)
end
