defmodule Jido.Workspace.Sandbox.Backend do
  @moduledoc """
  Backend lifecycle for services over a controller-owned local filesystem.

  The controller checks policy and file views before start. Backends own process
  creation and cleanup. A successful stop must stop the owned execution resource.
  See API_SPEC.md for capability, error, and ownership contracts.
  """
  alias Jido.Workspace.Sandbox.Backends.{AppleContainer, Docker, Local}

  @type state :: term()
  @type service :: map()
  @callback open(Jido.Workspace.Sandbox.t(), keyword()) ::
              {:ok, state(), map()} | {:error, term()}
  # A failed launch can leave a resource which still needs cleanup.
  @callback start_service(state(), map()) ::
              {:ok, service()} | {:error, term()} | {:error, :quiescence_unknown, service()}
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
        {:ok, Local, Keyword.take(opts, [:runner])}

      {:error, {:ok, provider}} when provider in [:docker, :gvisor] ->
        options = Keyword.take(opts, [:image, :workspace_read_only])
        runtime = if provider == :gvisor, do: "runsc", else: "runc"
        {:ok, Docker, Keyword.put(options, :runtime, runtime)}

      {:error, {:ok, :apple_container}} ->
        {:ok, AppleContainer, Keyword.take(opts, [:image, :workspace_read_only])}

      _ ->
        {:error, :unsupported_provider}
    end
  end

  @doc false
  def prepare(AppleContainer, opts), do: AppleContainer.prepare(opts)
  def prepare(_, opts), do: {:ok, opts}
end
