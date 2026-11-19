defmodule Jido.Workspace.Error do
  @moduledoc "An API error with an operation, a resource ID, and a bounded cause."

  @enforce_keys [:code, :operation, :message]
  defstruct [:code, :operation, :resource, :message, details: %{}]

  @type t :: %__MODULE__{
          code: atom(),
          operation: atom(),
          resource: String.t() | nil,
          message: String.t(),
          details: map()
        }

  @doc false
  @spec from_reason(atom(), String.t() | nil, term()) :: t()
  def from_reason(operation, resource, reason) do
    {code, message} = classify(reason)

    %__MODULE__{
      code: code,
      operation: operation,
      resource: resource,
      message: message,
      details: %{cause: inspect(diagnostic(reason), limit: 10, printable_limit: 200)}
    }
  end

  # Shell context can contain command text and environment values.
  defp diagnostic(%Jido.Shell.Error{code: code}), do: code
  defp diagnostic(reason), do: reason

  defp classify(%Jido.Shell.Error{code: {:vfs, code}}), do: classify(code)

  defp classify(%Jido.Shell.Error{code: {:shell, :network_blocked}}),
    do: {:policy_denied, "The Shell policy refused network access."}

  defp classify(%Jido.Shell.Error{code: {_, :busy}}), do: {:busy, "The session is busy."}
  defp classify(%Jido.Shell.Error{}), do: {:start_failed, "The Shell command failed."}

  defp classify(%Jido.VFS.Errors.StaleState{}),
    do: {:stale_revision, "The file revision changed."}

  defp classify(%Jido.VFS.Errors.UnsupportedOperation{}),
    do: {:unsupported_capability, "The backend does not support this operation."}

  defp classify(:multiple_mounts),
    do: {:unsupported_capability, "Captures require one root mount."}

  defp classify(:stale_file_view), do: {:stale_file_view, "The file view changed."}

  defp classify(:unversioned_file_view),
    do: {:unversioned_file_view, "The file view has no revision."}

  defp classify(:invalid_file_view), do: {:invalid_input, "The file view is invalid."}
  defp classify(:not_found), do: classify(:file_not_found)
  defp classify(:closed), do: {:closed, "The workspace is closed."}
  defp classify(:file_not_found), do: {:not_found, "The file does not exist."}
  defp classify(:already_exists), do: {:already_exists, "The path already exists."}
  defp classify(:directory_not_empty), do: {:directory_not_empty, "The directory is not empty."}
  defp classify(:not_directory), do: {:not_directory, "The path is not a directory."}
  defp classify(:enoent), do: classify(:not_found)
  defp classify(:eexist), do: classify(:already_exists)
  defp classify(:enotempty), do: classify(:directory_not_empty)
  defp classify(:enotdir), do: classify(:not_directory)
  defp classify(:busy), do: {:busy, "The workspace is busy."}

  defp classify(:unknown_profile),
    do: {:unknown_profile, "The host has no profile with this name."}

  defp classify(:invalid_profile), do: {:invalid_profile, "The workspace profile is invalid."}

  defp classify(:invalid_snapshot),
    do: {:invalid_snapshot, "The saved file tree failed validation."}

  defp classify(:snapshot_store_unconfigured),
    do: {:snapshot_store_unconfigured, "The profile has no configured snapshot store."}

  defp classify(:snapshot_too_large),
    do: {:snapshot_too_large, "The saved tree exceeds the store limits."}

  defp classify(:cleanup_unconfirmed),
    do: {:cleanup_unconfirmed, "Workspace could not confirm resource cleanup."}

  defp classify(:quiescence_unknown),
    do: {:quiescence_unknown, "Workspace could not confirm that writers have stopped."}

  defp classify(:unsupported_capability),
    do: {:unsupported_capability, "The backend does not support this operation."}

  defp classify({:unsupported_capability, _}), do: classify(:unsupported_capability)
  defp classify({:policy_denied, _}), do: {:policy_denied, "The policy refused the operation."}

  defp classify({kind, _}) when kind in [:invalid_path, :invalid_workspace_id, :invalid_command],
    do: {:invalid_input, "The input is invalid."}

  defp classify(reason) when reason in [:invalid_input, :invalid_policy, :path_traversal],
    do: {:invalid_input, "The input is invalid."}

  defp classify(_), do: {:operation_failed, "The workspace operation failed."}
end
