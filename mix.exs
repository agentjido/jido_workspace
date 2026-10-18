defmodule Jido.Workspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_workspace,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:jido, "~> 2.4.0", only: :test},
        {:jido_action, "~> 2.4.0", only: :test},
        {:jido_signal, "~> 2.3.2", only: :test},
        {:zoi, "~> 0.18.11"},
        {:splode, ">= 0.2.9 and < 0.4.0", override: true},
        {:jido_shell, path: "../jido_shell", override: true},
        {:jido_vfs, path: "../jido_vfs", override: true}
      ],
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      aliases: ["test.integration": &integration/1]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :sasl], mod: {Jido.Workspace.Application, []}]

  defp integration(args) do
    for file <- Path.wildcard("test/examples/**/*_test.exs") do
      {_, status} =
        System.cmd("mix", ["test", file, "--include", "integration"] ++ args,
          into: IO.stream(),
          env: [{"MIX_ENV", "test"}]
        )

      if status != 0, do: Mix.raise("Integration example failed: #{file}")
    end
  end
end
