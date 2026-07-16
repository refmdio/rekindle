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
      description: "Phoenix-native build system and development runtime for GPUI applications.",
      source_url: @source_url,
      package: package()
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w[lib mix.exs README.md LICENSE]
    ]
  end
end
