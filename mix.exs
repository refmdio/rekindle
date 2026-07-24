defmodule Rekindle.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/refmdio/rekindle"
  @docs_url "https://rekindle.hexdocs.pm"

  def project do
    [
      app: :rekindle,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Rekindle",
      description: "Elixir build system and development runtime for Rust UI applications.",
      homepage_url: @docs_url,
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:file_system, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:muontrap, "~> 1.8"},
      {:plug, "~> 1.16"},
      {:igniter, "~> 0.8", optional: true},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/introduction/getting-started.md",
        "guides/introduction/how-rekindle-works.md",
        "guides/features/integrations.md",
        "guides/features/configuration.md",
        "guides/features/development.md",
        "guides/features/web-target.md",
        "guides/features/desktop-target.md",
        "guides/deployment/production-builds.md",
        "guides/reference/troubleshooting.md",
        "guides/reference/cli.cheatmd"
      ],
      groups_for_extras: [
        Introduction: ~r"guides/introduction/",
        Features: ~r"guides/features/",
        Deployment: ~r"guides/deployment/",
        Reference: ~r"guides/reference/"
      ],
      groups_for_modules: [
        Core: [Rekindle, Rekindle.Phoenix],
        "Build results": [Rekindle.Build.Result, Rekindle.Diagnostic],
        Errors: [
          Rekindle.Build.Error,
          Rekindle.Cargo.Error,
          Rekindle.Config.Error,
          Rekindle.Desktop.Error,
          Rekindle.Toolchain.Error,
          Rekindle.Web.Error
        ],
        "Mix Tasks": [
          Mix.Tasks.Rekindle.Build,
          Mix.Tasks.Rekindle.Dev,
          Mix.Tasks.Rekindle.Doctor,
          Mix.Tasks.Rekindle.Install,
          Mix.Tasks.Rekindle.Setup
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Documentation" => @docs_url, "GitHub" => @source_url},
      files: ~w[lib priv/templates guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE]
    ]
  end
end
