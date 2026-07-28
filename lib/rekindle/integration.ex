defmodule Rekindle.Integration do
  @moduledoc false

  @type name :: :gpui | :egui | :slint
  @type target :: :web | :desktop

  @names [:gpui, :egui, :slint]
  @integrations %{
    gpui: %{
      dependency: "gpui",
      files: ["Cargo.lock", "Cargo.toml", "rust-toolchain.toml", "src/lib.rs"],
      graphics: %{web: :webgpu, desktop: :native},
      host: "",
      style: """
      * {
        box-sizing: border-box;
      }

      html,
      body {
        margin: 0;
        padding: 0;
        width: 100%;
        height: 100%;
        overflow: hidden;
      }

      body > canvas {
        display: block;
        width: 100%;
        height: 100%;
        touch-action: none;
        outline: none;
        -webkit-user-select: none;
        user-select: none;
      }
      """,
      template: "gpui"
    },
    egui: %{
      dependency: "eframe",
      files: ["Cargo.lock", "Cargo.toml", "rust-toolchain.toml", "src/lib.rs", "src/app.rs"],
      graphics: %{web: :webgl2, desktop: :native},
      host: ~s(<canvas id="the_canvas_id"></canvas>),
      style: """
      html {
        touch-action: manipulation;
      }

      body {
        background: #909090;
      }

      @media (prefers-color-scheme: dark) {
        body {
          background: #404040;
        }
      }

      html,
      body {
        overflow: hidden;
        margin: 0 !important;
        padding: 0 !important;
        width: 100%;
        height: 100%;
      }

      #the_canvas_id {
        display: block;
        position: absolute;
        inset: 0;
        width: 100%;
        height: 100%;
      }
      """,
      template: "egui"
    },
    slint: %{
      dependency: "slint",
      files: [
        "Cargo.lock",
        "Cargo.toml",
        "rust-toolchain.toml",
        "build.rs",
        "src/lib.rs",
        "ui/app-window.slint"
      ],
      graphics: %{web: :webgl2, desktop: :native},
      host: ~s(<canvas id="canvas"></canvas>),
      style: """
      html,
      body {
        overflow: hidden;
        margin: 0;
        padding: 0;
        width: 100%;
        height: 100%;
      }

      #canvas {
        display: block;
        position: absolute;
        inset: 0;
        width: 100%;
        height: 100%;
      }
      """,
      template: "slint"
    }
  }

  @spec names() :: [name()]
  def names, do: @names

  @spec fetch(name()) :: {:ok, map()} | :error
  def fetch(name), do: Map.fetch(@integrations, name)

  @spec dependency(name()) :: String.t()
  def dependency(name), do: @integrations |> Map.fetch!(name) |> Map.fetch!(:dependency)

  @spec host(name()) :: String.t()
  def host(name), do: @integrations |> Map.fetch!(name) |> Map.fetch!(:host)

  @spec style(name()) :: String.t()
  def style(name), do: @integrations |> Map.fetch!(name) |> Map.fetch!(:style)

  @spec render(name(), [target()], keyword()) :: %{String.t() => String.t()}
  def render(name, targets, options \\ []) do
    integration = Map.fetch!(@integrations, name)
    package_name = Keyword.get(options, :package_name, "client")
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
