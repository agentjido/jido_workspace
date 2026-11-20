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
      details: details(reason)
    }
  end

  defp details({:policy_denied, action} = reason) when is_atom(action),
    do: %{cause: cause(reason), action: action}

  defp details({:unsupported_capability, capability} = reason) when is_atom(capability),
    do: %{cause: cause(reason), capability: capability}

  defp details({:runtime_unavailable, runtime} = reason) when is_binary(runtime),
    do: %{cause: cause(reason), runtime: runtime}

  defp details(reason), do: %{cause: cause(reason)}

  defp cause(reason), do: inspect(diagnostic(reason), limit: 10, printable_limit: 200)

  # Shell context can contain command text and environment values.
  defp diagnostic(%Jido.Shell.Error{code: code}), do: code
  defp diagnostic(reason), do: reason

  defp classify(%Jido.Shell.Error{code: {:vfs, code}}), do: classify(code)

  defp classify(%Jido.Shell.Error{code: {:shell, :network_blocked}}),
    do: {:policy_denied, "The Shell policy refused network access."}

  defp classify(%Jido.Shell.Error{code: {_, :busy}}), do: {:busy, "The session is busy."}
  defp classify(%Jido.Shell.Error{}), do: {:start_failed, "The Shell command failed."}

  defp classify(%Jido.VFS.Errors.StaleState{}), do: classify(:stale_revision)
  defp classify(:stale_revision), do: {:stale_revision, "The file revision changed."}

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
  defp classify(:eisdir), do: {:is_directory, "The path is a directory."}
  defp classify(:symlink_path), do: {:symlink_path, "The path crosses a symbolic link."}
  defp classify(:enoent), do: classify(:not_found)
  defp classify(:eexist), do: classify(:already_exists)
  defp classify(:enotempty), do: classify(:directory_not_empty)
  defp classify(:enotdir), do: classify(:not_directory)
  defp classify(:busy), do: {:busy, "The workspace is busy."}

  defp classify(:transfer_limit),
    do: {:transfer_limit, "The file transfer exceeded its byte limit."}

  defp classify(:stream_failed), do: {:stream_failed, "The source stream could not finish."}

  defp classify(reason) when reason in [:discovery_entry_limit, :discovery_byte_limit],
    do: {:discovery_limit, "The file search exceeded a profile limit."}

  defp classify(:execution_not_active),
    do: {:execution_not_active, "The workspace has no active command with this ID."}

  defp classify(:invalid_command_reference),
    do: {:invalid_command_reference, "The durable command reference failed validation."}

  defp classify(:command_not_found),
    do: {:command_not_found, "The provider has no command with this reference."}

  defp classify(:command_reference_used),
    do: {:command_reference_used, "The provider already holds this command reference."}

  defp classify(:output_unavailable),
    do: {:output_unavailable, "The workspace has no output record for this command."}

  defp classify(:input_not_ready), do: {:input_not_ready, "The input pipe is not ready."}
  defp classify(:input_busy), do: {:input_busy, "The input pipe is busy."}
  defp classify(:input_closed), do: {:input_closed, "The command does not accept input."}

  defp classify(:service_not_ready),
    do: {:service_not_ready, "The command connection transport is not ready."}

  defp classify(:batch_timeout), do: {:batch_timeout, "The batch deadline expired."}

  defp classify(:checkout_busy),
    do: {:checkout_busy, "A workspace or container still holds the checkout."}

  defp classify(:checkout_changed),
    do: {:checkout_changed, "The checkout path no longer identifies the original directory."}

  defp classify(:checkout_restore_unsupported),
    do: {:checkout_restore_unsupported, "Open a disposable tree to restore a snapshot."}

  defp classify(:unknown_profile),
    do: {:unknown_profile, "The host has no profile with this name."}

  defp classify(:invalid_profile), do: {:invalid_profile, "The workspace profile is invalid."}

  defp classify(:provider_failed),
    do: {:provider_failed, "The workspace provider could not open."}

  defp classify(:invalid_infrastructure),
    do: {:invalid_infrastructure, "The infrastructure reference failed validation."}

  defp classify(:infrastructure_required),
    do: {:infrastructure_required, "The profile requires an infrastructure reference."}

  defp classify(:infrastructure_mismatch),
    do: {:infrastructure_mismatch, "The infrastructure does not match the request."}

  defp classify(:infrastructure_not_found),
    do: {:infrastructure_not_found, "The provider does not have access to that infrastructure."}

  defp classify(:infrastructure_unavailable),
    do: {:infrastructure_unavailable, "The provider could not reach the infrastructure."}

  defp classify(:infrastructure_busy),
    do: {:infrastructure_busy, "Another lease holds the infrastructure."}

  defp classify(:lease_revoked),
    do: {:lease_revoked, "The provider revoked the workspace lease."}

  defp classify(:infrastructure_restore_unsupported),
    do: {:infrastructure_restore_unsupported, "Select a separate profile to restore a snapshot."}

  defp classify(:owner_unavailable),
    do: {:owner_unavailable, "The workspace owner is unavailable."}

  defp classify(:opener_unavailable),
    do: {:opener_unavailable, "The workspace caller is unavailable."}

  defp classify(:open_timeout),
    do: {:open_timeout, "The allocation wait expired. Resource release can still be in progress."}

  defp classify(:invalid_snapshot),
    do: {:invalid_snapshot, "The saved file tree failed validation."}

  defp classify(:snapshot_store_unconfigured),
    do: {:snapshot_store_unconfigured, "The profile has no configured snapshot store."}

  defp classify({:snapshot_store_unavailable, _}),
    do: {:snapshot_store_unavailable, "The snapshot store could not complete the file operation."}

  defp classify(:snapshot_too_large),
    do: {:snapshot_too_large, "The saved tree exceeds the store limits."}

  defp classify(:cleanup_unconfirmed),
    do: {:cleanup_unconfirmed, "Workspace could not confirm resource cleanup."}

  defp classify(:quiescence_unknown),
    do: {:quiescence_unknown, "Workspace could not confirm that writers have stopped."}

  defp classify(:start_failed), do: {:start_failed, "The provider could not start the tool."}

  defp classify({:image_unavailable, _}),
    do: {:image_unavailable, "The required image is unavailable on the local engine."}

  defp classify({:backend_unavailable, :apple_container, :unsupported_host}),
    do: {:backend_unavailable, "Apple Container requires Apple silicon and macOS 26 or later."}

  defp classify({:backend_unavailable, :apple_container, :cli_not_found}),
    do: {:backend_unavailable, "Workspace could not find the Apple Container CLI on PATH."}

  defp classify({:backend_unavailable, :apple_container, :service_unavailable}),
    do: {:backend_unavailable, "Workspace could not reach the Apple Container service."}

  defp classify({:backend_unavailable, :apple_container, :unsupported_version}),
    do: {:backend_unavailable, "Workspace requires Apple Container 1.x, version 1.7.1 or later."}

  defp classify({:runtime_unavailable, _}),
    do: {:runtime_unavailable, "The engine does not list the required runtime."}

  defp classify(:unsupported_capability),
    do: {:unsupported_capability, "The backend does not support this operation."}

  defp classify({:unsupported_capability, _}), do: classify(:unsupported_capability)

  defp classify({:unsupported_file, _}),
    do: {:unsupported_capability, "The tree contains an unsupported entry type."}

  defp classify({:policy_denied, _}), do: {:policy_denied, "The policy refused the operation."}

  defp classify({kind, _}) when kind in [:invalid_path, :invalid_workspace_id, :invalid_command],
    do: {:invalid_input, "The input is invalid."}

  defp classify(reason)
       when reason in [:invalid_input, :invalid_policy, :path_traversal, :einval],
       do: {:invalid_input, "The input is invalid."}

  defp classify(_), do: {:operation_failed, "The workspace operation failed."}
end
