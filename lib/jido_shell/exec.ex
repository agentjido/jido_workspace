defmodule Jido.Shell.Exec do
  @moduledoc """
  Generic command execution helpers for shell-backed workflows.
  """

  @doc "Runs a command in a Shell session and returns its output."
  @spec run(module(), String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(shell_agent_mod, session_id, command, opts \\ [])
      when is_atom(shell_agent_mod) and is_binary(session_id) and is_binary(command) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    case shell_agent_mod.run(session_id, command, timeout: timeout) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Changes to the given directory before it runs the command."
  @spec run_in_dir(module(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run_in_dir(shell_agent_mod, session_id, cwd, command, opts \\ [])
      when is_atom(shell_agent_mod) and is_binary(session_id) and is_binary(cwd) and
             is_binary(command) do
    wrapped = "cd #{escape_path(cwd)} && #{command}"
    run(shell_agent_mod, session_id, wrapped, opts)
  end

  @doc "Quotes a path for use as a single shell argument."
  @spec escape_path(String.t()) :: String.t()
  def escape_path(path) when is_binary(path) do
    "'#{String.replace(path, "'", "'\\''")}'"
  end
end
