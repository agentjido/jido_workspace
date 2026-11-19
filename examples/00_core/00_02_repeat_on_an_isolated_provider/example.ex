defmodule Jido.Workspace.Examples.NativeReport do
  @moduledoc "Use the Sandbox file API and a native command on the same directory."

  alias Jido.Workspace.Sandbox

  def run(sandbox, input) do
    with :ok <- Sandbox.write(sandbox, "reports/input data.txt", input),
         {:ok, %{exit_status: 0}} <-
           Sandbox.exec(sandbox, "/bin/cp", ["input data.txt", "output data.txt"], dir: "reports") do
      Sandbox.read(sandbox, "reports/output data.txt")
    else
      {:ok, %{exit_status: _} = execution} -> {:error, execution}
      error -> error
    end
  end
end
