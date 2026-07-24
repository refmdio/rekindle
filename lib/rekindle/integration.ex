defmodule Rekindle.Integration do
  @moduledoc false

  @type name :: :gpui | :egui | :slint
  @type target :: :web | :desktop

  @names [:gpui, :egui, :slint]
  @integrations %{
    gpui: %{
      dependency: "gpui",
      files: ["Cargo.toml", "rust-toolchain.toml", "src/lib.rs"],
      graphics: %{web: :webgpu, desktop: :native},
      host: "",
      template: "gpui"
    },
    egui: %{
      dependency: "eframe",
      files: ["Cargo.toml", "rust-toolchain.toml", "src/lib.rs", "src/app.rs"],
      graphics: %{web: :webgl2, desktop: :native},
      host: ~s(<canvas id="rekindle-canvas"></canvas>),
      template: "egui"
    },
    slint: %{
      dependency: "slint",
      files: [
        "Cargo.toml",
        "rust-toolchain.toml",
        "build.rs",
        "src/lib.rs",
        "ui/app-window.slint"
      ],
      graphics: %{web: :webgl2, desktop: :native},
      host: ~s(<canvas id="canvas"></canvas>),
      template: "slint"
    }
  }

  @spec names() :: [name()]
  def names, do: @names

  @spec fetch(name()) :: {:ok, map()} | :error
  def fetch(name), do: Map.fetch(@integrations, name)

  @spec dependency(name()) :: String.t()
  def dependency(name), do: @integrations |> Map.fetch!(name) |> Map.fetch!(:dependency)

  @spec render(name(), [target()], keyword()) :: %{String.t() => String.t()}
  def render(name, targets, options \\ []) do
    integration = Map.fetch!(@integrations, name)
    package_name = Keyword.get(options, :package_name, "rekindle_client")
    crate_name = String.replace(package_name, "-", "_")

    assigns = [
      package_name: package_name,
      crate_name: crate_name,
      targets: targets,
      wasm_bindgen_version: Rekindle.Toolchain.wasm_bindgen_version()
    ]

    entries = Enum.map(targets, &"src/bin/#{&1}.rs")

    Map.new(integration.files ++ entries, fn path ->
      template =
        Application.app_dir(
          :rekindle,
          Path.join(["priv", "templates", "integrations", integration.template, path <> ".eex"])
        )

      {path, EEx.eval_file(template, assigns: assigns)}
    end)
  end
end
