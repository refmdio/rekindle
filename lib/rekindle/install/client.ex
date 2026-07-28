defmodule Rekindle.Install.Client do
  @moduledoc false

  alias Rekindle.Plugin
  alias Rekindle.Plugin.Cargo

  @type target :: :web | :desktop

  @spec render(Plugin.configured(), [target()]) :: %{String.t() => String.t()}
  def render(plugin, targets) do
    spec = Plugin.spec(plugin)

    static =
      Map.new(spec.files, fn {destination, source} ->
        {destination, Rekindle.Priv.read!(spec.source, source)}
      end)

    entries =
      Map.new(targets, fn target ->
        source = Map.fetch!(spec.entries, target)
        {"src/bin/#{target}.rs", Rekindle.Priv.read!(spec.source, source)}
      end)

    generated = %{
      "Cargo.toml" => Cargo.render(spec.cargo, targets),
      "rust-toolchain.toml" => toolchain(spec.toolchain, targets)
    }

    static
    |> Map.merge(entries)
    |> Map.merge(generated)
  end

  defp toolchain(channel, targets) do
    rust_targets = if :web in targets, do: ["wasm32-unknown-unknown"], else: []

    """
    [toolchain]
    channel = #{inspect(channel)}
    targets = #{inspect(rust_targets)}
    components = ["rustfmt", "clippy"]
    """
  end
end
