defmodule Jido.Workspace.Profile do
  @moduledoc """
  Host configuration for a shared file tree, runner, policy, and snapshot store.

      config :jido_workspace,
        profiles: %{
          build: %{
            provider: :memory,
            policy: :full_access,
            store: "results",
            require: %{isolation: :mediated, network: :disabled}
          }
        },
        stores: %{"results" => "/var/lib/my_app/workspace"}

  Use the name with `Jido.Workspace.open(profile: :build)`. Store paths belong
  to the host. Docker and gVisor profiles require a locally installed image.
  """

  @policies [:read_only, :workspace_write, :full_access]
  @providers [:memory, :docker, :gvisor]
  @virtual_tools ~w(cat cp echo ls mkdir pwd rm seq sleep write)

  @schema Zoi.map(
            %{
              provider: Zoi.enum(@providers),
              policy: Zoi.enum(@policies),
              image: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
              store: Zoi.string() |> Zoi.regex(~r/\A[A-Za-z0-9_-]{1,128}\z/) |> Zoi.optional(),
              tools: Zoi.array(Zoi.string() |> Zoi.min(1)) |> Zoi.optional(),
              require:
                Zoi.map(
                  %{
                    isolation: Zoi.enum([:mediated, :container, :gvisor]) |> Zoi.optional(),
                    network: Zoi.literal(:disabled) |> Zoi.optional()
                  },
                  unrecognized_keys: :error
                )
                |> Zoi.default(%{})
            },
            unrecognized_keys: :error
          )

  @doc "Returns the schema for a host profile."
  def schema, do: @schema

  @doc false
  def fetch(name) when is_atom(name) and not is_nil(name) do
    profiles = Application.get_env(:jido_workspace, :profiles, %{})

    with {:ok, options} <- find(profiles, name),
         {:ok, attrs} <- attributes(options),
         {:ok, profile} <- Zoi.parse(@schema, attrs),
         :ok <- validate_provider(profile) do
      {:ok, profile}
    else
      :error -> {:error, :unknown_profile}
      _ -> {:error, :invalid_profile}
    end
  end

  def fetch(_), do: {:error, :invalid_profile}

  @doc false
  def allows_tool?(%{provider: :memory} = profile, tool),
    do: tool in Map.get(profile, :tools, @virtual_tools)

  def allows_tool?(profile, tool) do
    case Map.fetch(profile, :tools) do
      {:ok, tools} -> tool in tools
      :error -> true
    end
  end

  defp find(profiles, name) when is_map(profiles), do: Map.fetch(profiles, name)
  defp find(profiles, name) when is_list(profiles), do: Keyword.fetch(profiles, name)
  defp find(_, _), do: :error

  defp attributes(options) when is_map(options), do: {:ok, options}

  defp attributes(options) do
    if Keyword.keyword?(options), do: {:ok, Map.new(options)}, else: :error
  end

  defp validate_provider(%{provider: :memory} = profile) do
    if not Map.has_key?(profile, :image) and
         Enum.all?(Map.get(profile, :tools, []), &(&1 in @virtual_tools)),
       do: :ok,
       else: :error
  end

  defp validate_provider(profile), do: if(Map.has_key?(profile, :image), do: :ok, else: :error)
end
