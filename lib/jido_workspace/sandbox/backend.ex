defmodule Jido.Workspace.Sandbox.Backend do
  @moduledoc """
  Backend lifecycle for services over a controller-owned local filesystem.

  The controller checks policy and file views before start. Backends own process
  creation and cleanup. A successful stop must stop the owned execution resource.
  See API_SPEC.md for capability, error, and ownership contracts.
  """
  alias Jido.Workspace.Sandbox.Backends.{Local, Docker}

  @type state :: term()
  @type service :: map()
  @callback open(Jido.Workspace.Sandbox.t(), keyword()) ::
              {:ok, state(), map()} | {:error, term()}
  @callback start_service(state(), map()) :: {:ok, service()} | {:error, term()}
  @callback finish_service(state(), service(), integer()) :: {:ok, service()} | {:error, term()}
  @callback stop_service(state(), service()) :: :ok | {:error, term()}
  @callback destroy(state()) :: :ok | {:error, term()}

  @doc false
  def resolve(opts) do
    case {Keyword.fetch(opts, :backend), Keyword.fetch(opts, :provider)} do
      {{:ok, {module, options}}, :error} when module in [Local, Docker] and is_list(options) ->
        if Keyword.keyword?(options),
          do: {:ok, module, options},
          else: {:error, :invalid_backend_options}

      {:error, provider} when provider in [:error, {:ok, :local}] ->
        {:ok, Local, []}

      {:error, {:ok, provider}} when provider in [:docker, :gvisor] ->
        options = Keyword.take(opts, [:image])
        runtime = if provider == :gvisor, do: "runsc", else: "runc"
        {:ok, Docker, Keyword.put(options, :runtime, runtime)}

      _ ->
        {:error, :unsupported_provider}
    end
  end
end
