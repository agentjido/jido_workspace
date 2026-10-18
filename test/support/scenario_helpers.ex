defmodule Jido.Workspace.TestSupport.ScenarioHelpers do
  @moduledoc false

  alias Jido.Workspace

  @workspace_process_key {__MODULE__, :workspace_under_test}

  @spec new_local_workspace!(String.t(), String.t(), String.t()) :: %{
          workspace: Jido.Workspace.t(),
          workspace_id: String.t(),
          output_root: String.t()
        }
  def new_local_workspace!(scenario_slug, id_prefix, tmp_dir)
      when is_binary(scenario_slug) and is_binary(id_prefix) and is_binary(tmp_dir) do
    workspace_id = unique_workspace_id(id_prefix)
    output_root = Path.join(tmp_dir, scenario_slug)
    :ok = File.mkdir_p!(output_root)

    workspace =
      Workspace.open(
        id: workspace_id,
        adapter: Jido.VFS.Adapter.Local,
        adapter_opts: [prefix: output_root]
      )

    case workspace do
      {:ok, %Jido.Workspace.Workspace{} = ws} ->
        put_workspace(ws)

        %{
          workspace: ws,
          workspace_id: workspace_id,
          output_root: output_root
        }

      {:error, reason} ->
        raise ArgumentError,
              "failed to initialize scenario workspace #{inspect(workspace_id)}: #{inspect(reason)}"
    end
  end

  @spec put_workspace(Jido.Workspace.t()) :: Jido.Workspace.t()
  def put_workspace(%Jido.Workspace.Workspace{} = workspace) do
    Process.put(@workspace_process_key, workspace)
    workspace
  end

  @spec current_workspace() :: Jido.Workspace.t() | nil
  def current_workspace do
    Process.get(@workspace_process_key)
  end

  @spec close_workspace_if_present() :: :ok
  def close_workspace_if_present do
    case current_workspace() do
      %Jido.Workspace.Workspace{} = workspace ->
        _ = Workspace.close(workspace)
        Process.delete(@workspace_process_key)
        :ok

      _ ->
        :ok
    end
  end

  @spec write_error_artifact(String.t(), any(), Exception.stacktrace()) :: :ok
  def write_error_artifact(path, error, stacktrace) do
    case current_workspace() do
      %Jido.Workspace.Workspace{} = workspace ->
        _ = Workspace.write(workspace, path, error_summary_json(error, stacktrace))
        :ok

      _ ->
        :ok
    end
  end

  @spec summary_json(String.t(), String.t(), String.t(), [{String.t() | atom(), any()}]) ::
          String.t()
  def summary_json(scenario, status, workspace_id, extra_fields \\ [])
      when is_binary(scenario) and is_binary(status) and is_binary(workspace_id) and
             is_list(extra_fields) do
    fields =
      [
        {"scenario", scenario},
        {"status", status},
        {"workspace_id", workspace_id}
      ] ++ extra_fields

    json_object(fields)
  end

  @spec error_summary_json(any(), Exception.stacktrace()) :: String.t()
  def error_summary_json(error, stacktrace) do
    json_object([
      {"status", "error"},
      {"reason", Exception.format(:error, error, stacktrace)}
    ])
  end

  @spec json_escape(String.t()) :: String.t()
  def json_escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  @spec json_string_list([String.t()]) :: String.t()
  def json_string_list(values) when is_list(values) do
    values
    |> Enum.map(&json_value/1)
    |> Enum.join(", ")
  end

  defp unique_workspace_id(prefix) do
    "#{prefix}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp json_object(fields) when is_list(fields) do
    encoded =
      fields
      |> Enum.map(fn {key, value} ->
        "\"#{json_escape(to_string(key))}\": #{json_value(value)}"
      end)
      |> Enum.join(",\n  ")

    "{\n  #{encoded}\n}"
  end

  defp json_value(value) when is_binary(value), do: "\"#{json_escape(value)}\""
  defp json_value(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp json_value(value) when is_integer(value), do: Integer.to_string(value)
  defp json_value(value) when is_float(value), do: Float.to_string(value)

  defp json_value(values) when is_list(values) do
    "[#{Enum.map_join(values, ", ", &json_value/1)}]"
  end

  defp json_value(value), do: "\"#{json_escape(inspect(value))}\""
end
