defmodule Jido.Workspace.Profile do
  @moduledoc """
  Host configuration for a shared file tree, runner, policy, and snapshot store.

      config :jido_workspace,
        profiles: %{
          build: %{
            provider: :memory,
            policy: :full_access,
            store: "results",
            require: %{isolation: :mediated, network: :disabled},
            limits: %{timeout_ms: 5_000, output_limit: 4_096}
          }
        },
        stores: %{"results" => "/var/lib/my_app/workspace"}

  Use the name with `Jido.Workspace.open(profile: :build)`. Store paths belong
  to the host. Use `provider: {MyApp.Provider, options}` to select a host
  module that implements `Jido.Workspace.Provider`.
  Set `infrastructure: "provider-name"` on a persistent provider profile.
  Each open then requires a durable reference in that provider namespace.
  Docker, gVisor, and `:apple_container` profiles require a locally installed
  image. Apple Container requires Apple silicon, macOS 26 or later, and a
  running Apple Container 1.x service, version 1.7.1 or later. Select it
  explicitly in a named profile.
  Set `checkout:` to an existing absolute directory path to use a host-owned
  tree on local, Docker, or gVisor profiles. Closing Workspace preserves that
  directory. A `:local` profile without `checkout:` creates a disposable
  directory. Local commands run with the host user's filesystem and network
  access. Use trusted tools. Set
  `runner: :erlexec` to supervise a private process group. The default
  `runner: :port` tracks the direct child. A tool must keep all writers
  within the bounds of the selected runner.
  Local profiles with execute permission must also grant write permission and
  list the absolute paths of the approved tools.
  The optional `timeout_ms` and `output_limit` limits cap each command.
  The `batch_timeout_ms` deadline defaults to 60,000 ms. The
  `batch_output_limit` cap defaults to 1 MiB for all command results in a
  batch. A command can also request a lower timeout or output limit.
  Use `require: %{runtime_limits: %{pids: 256}}` to require a provider
  that enforces a ceiling of 256 tasks or fewer per command container.
  The supported keys are `:pids`, `:memory_bytes`, `:cpu_millicores`, and
  `:tmp_bytes`. A requirement checks the provider's limit at open.
  Add `stdin: :pipe` to `require` when opening the workspace must verify
  that the provider can accept input during a run.
  Add `cancellation: :process_group` to require process-group supervision.
  Add `network: :disabled` to `require` to check the provider's network
  restriction at open. Memory meets this requirement through its virtual tools.
  Docker uses the `none` network driver for each command. The command
  container has its own loopback interface.
  A Docker profile can set `service: %{ports: [8080], connector: "/usr/bin/nc"}`.
  The connector is an executable in the image that forwards bytes between
  its standard streams and the supplied IPv4 address and TCP port. The
  host selects a trusted connector from the image's read-only filesystem.
  Only the listed loopback ports are available through
  `Jido.Workspace.connect/3`. No host port is published.
  Use `discovery:` to select the paths and content that `Jido.Workspace.find/3`
  searches and to bound the work each search can do.
  Use `limits: %{write_stream_bytes: bytes}` to cap each streamed write.
  The default limit is 64 MiB.

  Use `tools:` to restrict the first argument of each command. Workspace
  checks the exact name before a direct run or batch step. Memory validates
  the configured names against its virtual tools at open. Docker and Apple
  Container resolve the name in the image and workspace at command start.
  Add `"lua"` explicitly to a memory profile to run Lua scripts from
  the tree. Running Lua requires write permission. Lua publishes its
  staged files when evaluation succeeds.

  Set `policy:` to a preset or to an explicit list of permissions.
  The list can contain `:read`, `:write`, `:execute`, `:import`, `:save`, and
  `:recover`. A persistent provider profile with only `[:recover]` can
  inspect, wait for, and stop durable commands without opening a session.
  Execution requires read access to the tree. When write permission is
  absent, memory runs only read-only virtual tools. Docker runs with a read-only
  workspace mount that excludes submounts. Apple Container uses a read-only
  mount of its disposable workspace directory.
  Import permits opening a saved snapshot from the profile's store.
  Save permits publishing a snapshot to that store. Both are independent
  of file write permission.
  """

  alias Jido.Workspace.{Discovery, InfrastructureRef, Policy, Provider, Schemas}

  @providers [:memory, :local, :docker, :gvisor, :apple_container]
  @read_only_tools ~w(cat echo ls pwd seq sleep)
  @virtual_tools @read_only_tools ++ ~w(cp mkdir rm write)
  @memory_tools @virtual_tools ++ ["lua"]
  @isolation [:mediated, :process, :container, :gvisor]
  @cancellation [:cooperative, :direct_child, :process_group, :container]
  @runtime_limit_keys [:pids, :memory_bytes, :cpu_millicores, :tmp_bytes]
  @runtime_limits_schema Zoi.map(
                           Map.new(@runtime_limit_keys, fn key ->
                             {key, Zoi.integer() |> Zoi.min(1) |> Zoi.optional()}
                           end),
                           unrecognized_keys: :error
                         )

  @service_schema Zoi.map(
                    %{
                      ports:
                        Zoi.array(Zoi.integer() |> Zoi.min(1) |> Zoi.max(65_535)) |> Zoi.min(1),
                      connector: Zoi.string() |> Zoi.min(1)
                    },
                    unrecognized_keys: :error
                  )

  @capabilities_schema Zoi.map(
                         %{
                           tree_access: Zoi.enum([:read_only, :read_write]),
                           isolation: Zoi.enum(@isolation) |> Zoi.optional(),
                           cancellation: Zoi.enum(@cancellation) |> Zoi.optional(),
                           network: Zoi.enum([:disabled, :host]) |> Zoi.optional(),
                           runtime_limits: @runtime_limits_schema |> Zoi.default(%{})
                         },
                         unrecognized_keys: :error
                       )

  @schema Zoi.map(
            %{
              provider: Zoi.union([Zoi.enum(@providers), Zoi.tuple({Zoi.atom(), Zoi.any()})]),
              infrastructure: Zoi.optional(InfrastructureRef.provider_schema()),
              policy: Policy.schema(),
              image: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
              runner: Zoi.enum([:port, :erlexec]) |> Zoi.optional(),
              checkout: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
              store: Zoi.string() |> Zoi.regex(~r/\A[A-Za-z0-9_-]{1,128}\z/) |> Zoi.optional(),
              tools: Zoi.array(Zoi.string() |> Zoi.min(1)) |> Zoi.optional(),
              service: Zoi.optional(@service_schema),
              discovery: Discovery.schema(),
              limits:
                Zoi.map(
                  %{
                    timeout_ms: Schemas.run_timeout_schema() |> Zoi.optional(),
                    output_limit: Schemas.run_output_limit_schema() |> Zoi.optional(),
                    batch_timeout_ms: Schemas.run_timeout_schema() |> Zoi.optional(),
                    batch_output_limit: Schemas.run_output_limit_schema() |> Zoi.optional(),
                    write_stream_bytes:
                      Zoi.integer() |> Zoi.min(1) |> Zoi.max(1_073_741_824) |> Zoi.optional()
                  },
                  unrecognized_keys: :error
                )
                |> Zoi.default(%{}),
              require:
                Zoi.map(
                  %{
                    isolation: Zoi.enum(@isolation) |> Zoi.optional(),
                    network: Zoi.literal(:disabled) |> Zoi.optional(),
                    stdin: Zoi.literal(:pipe) |> Zoi.optional(),
                    cancellation: Zoi.enum(@cancellation) |> Zoi.optional(),
                    runtime_limits: Zoi.optional(@runtime_limits_schema)
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
  def provider_capabilities(capabilities), do: Zoi.parse(@capabilities_schema, capabilities)

  @doc false
  def fetch(name) when is_atom(name) and not is_nil(name) do
    profiles = Application.get_env(:jido_workspace, :profiles, %{})

    case find(profiles, name) do
      {:ok, options} -> parse(options)
      :error -> {:error, :unknown_profile}
    end
  end

  def fetch(options) when is_map(options), do: parse(options)

  def fetch(_), do: {:error, :invalid_profile}

  defp parse(options) do
    with {:ok, attrs} <- attributes(options),
         {:ok, profile} <- Zoi.parse(@schema, attrs),
         :ok <- validate_policy(profile.policy),
         :ok <- Discovery.validate(profile.discovery),
         :ok <- validate_provider(profile),
         :ok <- validate_infrastructure(profile),
         :ok <- validate_service(profile) do
      {:ok, profile}
    else
      _ -> {:error, :invalid_profile}
    end
  end

  @doc false
  def allows_tool?(%{provider: :memory, policy: policy} = profile, tool) do
    tool in Map.get(profile, :tools, @virtual_tools) and
      (tool in @read_only_tools or Policy.allows?(policy, :write))
  end

  def allows_tool?(profile, tool) do
    case Map.fetch(profile, :tools) do
      {:ok, tools} -> tool in tools
      :error -> true
    end
  end

  @doc false
  def command_limits(profile) do
    Map.merge(Schemas.command_limits(), Map.take(profile.limits, [:timeout_ms, :output_limit]))
  end

  @doc false
  def limit_run(profile, opts) do
    Map.merge(opts, command_limits(profile), fn _, requested, maximum ->
      min(requested, maximum)
    end)
  end

  @doc false
  def infrastructure(%{infrastructure: provider}, {:ok, value}) do
    case InfrastructureRef.parse(value) do
      {:ok, %{provider: ^provider} = reference} -> {:ok, reference}
      {:ok, _} -> {:error, :infrastructure_mismatch}
      {:error, _} -> {:error, :invalid_infrastructure}
    end
  end

  def infrastructure(%{infrastructure: _}, :error), do: {:error, :infrastructure_required}
  def infrastructure(_, :error), do: {:ok, nil}
  def infrastructure(_, {:ok, _}), do: {:error, {:unsupported_capability, :infrastructure}}

  defp find(profiles, name) when is_map(profiles), do: Map.fetch(profiles, name)
  defp find(profiles, name) when is_list(profiles), do: Keyword.fetch(profiles, name)
  defp find(_, _), do: :error

  defp attributes(options) when is_map(options), do: {:ok, options}

  defp attributes(options) do
    if Keyword.keyword?(options), do: {:ok, Map.new(options)}, else: :error
  end

  defp validate_policy(policy) do
    if Policy.allows?(policy, :execute), do: Policy.authorize(policy, :read), else: :ok
  end

  defp validate_provider(%{provider: provider, runner: _}) when provider != :local, do: :error

  defp validate_provider(%{provider: {module, _}} = profile) do
    if not Map.has_key?(profile, :image) and not Map.has_key?(profile, :checkout) and
         Provider.configured?(module),
       do: :ok,
       else: :error
  end

  defp validate_provider(%{provider: :memory} = profile) do
    if not Map.has_key?(profile, :image) and not Map.has_key?(profile, :checkout) and
         Enum.all?(Map.get(profile, :tools, []), &(&1 in @memory_tools)),
       do: :ok,
       else: :error
  end

  defp validate_provider(%{provider: :local} = profile) do
    if Map.has_key?(profile, :image) or
         (Map.has_key?(profile, :checkout) and not absolute_path?(profile.checkout)) do
      :error
    else
      validate_local_execution(profile)
    end
  end

  defp validate_provider(%{provider: :apple_container, checkout: _}), do: :error

  defp validate_provider(%{image: _, checkout: path}) do
    if absolute_path?(path), do: :ok, else: :error
  end

  defp validate_provider(profile), do: if(Map.has_key?(profile, :image), do: :ok, else: :error)

  defp validate_infrastructure(%{provider: {_, _}}), do: :ok
  defp validate_infrastructure(%{infrastructure: _}), do: :error
  defp validate_infrastructure(_), do: :ok

  defp validate_local_execution(profile) do
    if Policy.allows?(profile.policy, :execute) do
      tools = Map.get(profile, :tools, [])

      if Policy.allows?(profile.policy, :write) and tools != [] and
           Enum.all?(tools, &absolute_path?/1),
         do: :ok,
         else: :error
    else
      :ok
    end
  end

  defp validate_service(%{provider: :docker, service: service, policy: policy}) do
    connector = service.connector

    with :ok <- Policy.authorize(policy, :execute),
         true <- absolute_path?(connector) and connector == Path.expand(connector),
         false <-
           Enum.at(Path.split(connector), 1) in ["workspace", "tmp", "dev", "proc", "sys", nil],
         true <- Enum.uniq(service.ports) == service.ports do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_service(%{service: _}), do: :error
  defp validate_service(_), do: :ok

  defp absolute_path?(path),
    do: String.valid?(path) and Path.type(path) == :absolute and not String.contains?(path, <<0>>)
end
