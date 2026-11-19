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
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:mix]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.examples": :test,
        "test.coverage": :test,
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :sasl, :ssh, :public_key],
      mod: {Jido.Workspace.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:zoi, "~> 0.19.0"},
      {:splode, "~> 0.3.0"},
      {:jason, "~> 1.4"},
      {:uniq, "~> 0.6"},
      {:bash, "~> 0.6.0", optional: true},
      {:lua, "~> 1.0.0-rc.1"},
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.2"},
      {:sweet_xml, "~> 0.6"},
      {:eternal, "~> 1.2.2"},
      {:git_cli, "~> 0.3.0"},
      {:req, "~> 0.6"},
      {:igniter, "~> 0.7", optional: true},

      # Agent boundary checks
      {:jido,
       github: "agentjido/jido", ref: "047bf746330a2fbe7c3b25c045552e0303c97eaf", only: :test},

      # Dev/Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:mimic, "~> 2.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:minio_server, "~> 0.4.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      "test.examples": &examples/1,
      "test.integration": &integration/1,
      "test.coverage": &coverage/1,
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "jido_shell.guardrails",
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
        "docs/shell",
        "docs/vfs",
        "docs/source-imports.md",
        "docs/workspace-asset-lifecycle.md",
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
        {"docs/shell/README.md", filename: "shell"},
        "docs/shell/GUARDRAILS.md",
        "docs/shell/MIGRATION.md",
        {"docs/vfs/README.md", filename: "vfs"},
        "docs/vfs/adapter-onboarding-checklist.md",
        "docs/vfs/jido-agent-integration.md",
        "docs/source-imports.md",
        "docs/workspace-asset-lifecycle.md",
        "LICENSE"
      ]
    ]
  end

  defp examples(args) do
    Mix.Task.run(
      "test",
      numbered_example_files() ++ ["--include", "integration" | args]
    )
  end

  defp integration(args) do
    for file <- integration_example_files() do
      {_, status} =
        System.cmd("mix", ["test", file, "--include", "integration"] ++ args,
          into: IO.stream(),
          env: [{"MIX_ENV", "test"}]
        )

      if status != 0, do: Mix.raise("Integration example failed: #{file}")
    end
  end

  defp coverage(args) do
    output = "cover/examples"
    File.rm_rf!(output)
    File.mkdir_p!(output)

    for {file, index} <- Enum.with_index(integration_example_files()) do
      coverage_run(
        [
          "coveralls.json",
          file,
          "--include",
          "integration",
          "--export-coverage",
          "examples/#{index}"
        ] ++
          args
      )
    end

    vfs_examples =
      Path.wildcard("test/jido_vfs/adapter/{ets,git,in_memory,local}_integration_test.exs")

    coverage_run(
      ["coveralls.json", "--include", "integration", "--export-coverage", "examples/vfs"] ++
        vfs_examples ++ args
    )

    coverage_run(["coveralls.json", "--import-cover", output] ++ args)
    coverage_run(["coveralls", "--import-cover", output] ++ args)
  end

  defp coverage_run(args) do
    {_, status} =
      System.cmd("mix", args,
        into: IO.stream(),
        env: [{"MIX_ENV", "test"}, {"JIDO_COVERAGE_DIR", Path.expand("cover/examples")}]
      )

    if status != 0, do: Mix.raise("Coverage test run failed")
  end

  defp integration_example_files do
    numbered_example_files() ++ Path.wildcard("test/examples/**/*_test.exs")
  end

  defp numbered_example_files, do: Path.wildcard("examples/**/*_test.exs")
end
