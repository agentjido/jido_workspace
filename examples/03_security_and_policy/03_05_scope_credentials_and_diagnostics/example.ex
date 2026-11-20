defmodule Jido.Workspace.Examples.VerifyCredential do
  @moduledoc "Send a fixture credential to one approved command."

  alias Jido.Workspace

  @tool "/workspace/bin/verify"

  def profile(checkout, image) do
    %{
      provider: :docker,
      checkout: checkout,
      image: image,
      store: "reports",
      policy: [:read, :execute, :save],
      tools: [@tool],
      require: %{isolation: :container, network: :disabled, stdin: :pipe},
      limits: %{output_limit: 0}
    }
  end

  def run(workspace) do
    Workspace.run(workspace, [@tool], stdin: :pipe, timeout_ms: 20_000)
  end

  def submit(workspace, execution_id, credential) do
    Workspace.input(workspace, execution_id, credential <> "\n")
  end
end
