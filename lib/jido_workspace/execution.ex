defmodule Jido.Workspace.Execution do
  @moduledoc "A completed command with bounded combined output and file observations."
  @enforce_keys [:id, :command, :status, :files, :after_files, :duration_ms]
  defstruct [
    :id,
    :command,
    :status,
    :exit_status,
    :files,
    :after_files,
    :duration_ms,
    output: "",
    truncated: false
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          command: String.t(),
          status: :exited | :timed_out | :cancelled,
          exit_status: integer() | nil,
          files: Jido.Workspace.FileView.t(),
          after_files: Jido.Workspace.FileView.t() | {:error, Jido.Workspace.Error.t()},
          duration_ms: non_neg_integer(),
          output: binary(),
          truncated: boolean()
        }
end
