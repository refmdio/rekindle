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
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:toml_elixir, "~> 3.1"},
      {:igniter, "~> 0.8", optional: true}
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
