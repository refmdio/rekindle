defmodule Rekindle.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/refmdio/rekindle"

  def project do
    [
      app: :rekindle,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Rekindle",
      description: "Mix-first build system and development runtime for Rust UI applications.",
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
      extras: ["README.md"],
      source_url: @source_url
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w[lib priv/templates mix.exs README.md LICENSE]
    ]
  end
end
