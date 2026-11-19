defmodule Jido.Workspace.Schemas do
  @moduledoc """
  Zoi schemas for workspace inputs.
  """

  @doc """
  Absolute workspace path schema.
  """
  @spec path_schema() :: term()
  def path_schema do
    Zoi.string()
    |> Zoi.min(1)
    |> Zoi.refine(fn path ->
      cond do
        not String.starts_with?(path, "/") ->
          {:error, "path must be absolute (start with /)"}

        traversal?(path) ->
          {:error, "path traversal (..) is not allowed"}

        true ->
          :ok
      end
    end)
  end

  @doc """
  Workspace id schema.
  """
  @spec workspace_id_schema() :: term()
  def workspace_id_schema do
    Zoi.string()
    |> Zoi.min(1)
    |> Zoi.refine(fn id ->
      if String.trim(id) == "" do
        {:error, "workspace id cannot be blank"}
      else
        :ok
      end
    end)
  end

  @doc """
  Shell command schema.
  """
  @spec command_schema() :: term()
  def command_schema do
    Zoi.string()
    |> Zoi.min(1)
    |> Zoi.refine(fn command ->
      if String.trim(command) == "" do
        {:error, "command cannot be blank"}
      else
        :ok
      end
    end)
  end

  @doc """
  Validates and normalizes an absolute path.
  """
  @spec validate_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate_path(path) do
    case Zoi.parse(path_schema(), path) do
      {:ok, validated} -> {:ok, normalize_absolute_path(validated)}
      {:error, errors} -> {:error, {:invalid_path, format_errors(errors)}}
    end
  end

  @doc """
  Validates workspace id.
  """
  @spec validate_workspace_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate_workspace_id(id) do
    case Zoi.parse(workspace_id_schema(), id) do
      {:ok, validated} -> {:ok, String.trim(validated)}
      {:error, errors} -> {:error, {:invalid_workspace_id, format_errors(errors)}}
    end
  end

  @doc """
  Validates command text.
  """
  @spec validate_command(String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate_command(command) do
    case Zoi.parse(command_schema(), command) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, {:invalid_command, format_errors(errors)}}
    end
  end

  @doc "Checks a canonical workspace-relative path. A single dot names the root."
  def relative_path?("."), do: true

  def relative_path?(path) when is_binary(path) and byte_size(path) in 1..4096 do
    String.valid?(path) and Jido.VFS.RelativePath.relative?(path) and
      not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  def relative_path?(_), do: false

  @doc false
  def durable_id_schema do
    Zoi.string()
    |> Zoi.min(1)
    |> Zoi.max(1024)
    |> Zoi.refine(&__MODULE__.validate_durable_id/1)
  end

  @doc false
  def validate_durable_id(id) do
    if String.valid?(id) and String.trim(id) != "" and not String.contains?(id, <<0>>),
      do: :ok,
      else: {:error, "identifier must be nonblank UTF-8 text"}
  end

  defp traversal?(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.any?(&(&1 == ".."))
  end

  defp normalize_absolute_path(path) do
    path
    |> Path.expand("/")
    |> String.replace(~r{/+}, "/")
  end

  defp format_errors(errors) do
    Enum.map_join(errors, "; ", &format_error/1)
  end

  defp format_error(%{message: message, path: path}) when path != [] do
    "#{Enum.join(path, ".")}: #{message}"
  end

  defp format_error(%{message: message}), do: message
end
