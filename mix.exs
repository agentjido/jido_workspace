defmodule Jido.Workspace.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_workspace"
  @description "Unified artifact workspace for agent sessions (Jido.Shell + Jido.VFS)"

  def project do
    [
      app: :jido_workspace,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Documentation
      name: "Jido.Workspace",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),

      # Test Coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90]
      ],

      # Dialyzer
      dialyzer: [plt_local_path: "priv/plts/project.plt", plt_core_path: "priv/plts/core.plt"]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :sasl],
      mod: {Jido.Workspace.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:zoi, "~> 0.18.11"},
      {:splode, ">= 0.2.9 and < 0.4.0", override: true},
      stack_dep(:jido_shell, "e46a4e33069b2e961ef0e6b14de50a574c7730d7"),
      stack_dep(:jido_vfs, "3383487d48603c1b935858a964f53a44989efa21"),

      # Agent boundary checks
      {:jido, "~> 2.4.0", only: :test},
      {:jido_action, "~> 2.4.0", only: :test},
      {:jido_signal, "~> 2.3.2", only: :test},

      # Dev/Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end

  defp stack_dep(name, ref) do
    path = "../#{name}"

    if File.regular?(Path.expand("#{path}/mix.exs", __DIR__)) do
      {name, path: path, override: true}
    else
      {name, github: "agentjido/#{name}", ref: ref, override: true}
    end
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      "test.integration": &integration/1,
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end

  defp package do
    [
      files: [
        ".formatter.exs",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "README.md",
        "config",
        "lib",
        "src",
        "API_SPEC.md",
        "SANDBOX.md",
        "DEPLOY.md",
        "mix.exs",
        "usage-rules.md"
      ],
      maintainers: ["Agent Jido Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jido_workspace/changelog.html",
        "Discord" => "https://agentjido.xyz/discord",
        "Documentation" => "https://hexdocs.pm/jido_workspace",
        "GitHub" => @source_url,
        "Website" => "https://agentjido.xyz"
      }
    ]
  end

  defp docs do
    [
      main: "Jido.Workspace",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "API_SPEC.md",
        "SANDBOX.md",
        "DEPLOY.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ]
    ]
  end

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
