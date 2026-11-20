defmodule Jido.Workspace.InfrastructureRef do
  @moduledoc "A durable provider and resource identity for host-managed infrastructure."

  @provider_schema Zoi.string() |> Zoi.regex(~r/\A[A-Za-z0-9_-]{1,128}\z/)

  @schema Zoi.map(
            %{
              kind: Zoi.literal("infrastructure"),
              format: Zoi.literal(1),
              provider: @provider_schema,
              resource_id: Jido.Workspace.Schemas.durable_id_schema()
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @type t :: %{
          kind: String.t(),
          format: 1,
          provider: String.t(),
          resource_id: String.t()
        }

  @doc "Returns the schema for the durable reference."
  def schema, do: @schema

  @doc false
  def provider_schema, do: @provider_schema

  @doc "Builds a reference from a provider name and its resource ID."
  def new(provider, resource_id),
    do: parse(%{kind: "infrastructure", format: 1, provider: provider, resource_id: resource_id})

  @doc "Validates a reference, including one decoded from JSON."
  def parse(value), do: Zoi.parse(@schema, value)
end
