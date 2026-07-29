defmodule Rekindle.Plugin.Egui do
  @moduledoc "Built-in egui/eframe support."

  @behaviour Rekindle.Plugin

  alias Rekindle.Plugin.{Cargo, Spec}
  alias Rekindle.Plugin.Cargo.Dependency

  @impl true
  def name, do: "egui"

  @impl true
  def spec(_options) do
    %Spec{
      name: name(),
      dependency: "eframe",
      source: {:rekindle, "templates/client/egui"},
      files: %{
        "Cargo.lock" => "Cargo.lock",
        "src/lib.rs" => "src/lib.rs",
        "src/app.rs" => "src/app.rs"
      },
      entries: %{
        web: "src/bin/web.rs",
        desktop: "src/bin/desktop.rs"
      },
      cargo: %Cargo{
        dependencies: [
          %Dependency{name: "serde", version: "1", features: ["derive"]}
        ],
        dev_dependencies: [
          %Dependency{name: "egui_kittest", version: "=0.35.0", features: ["eframe"]}
        ],
        target_dependencies: [
          {"cfg(not(target_arch = \"wasm32\"))",
           [
             %Dependency{
               name: "eframe",
               version: "0.35",
               default_features: false,
               features: ["default_fonts", "glow", "persistence", "wayland", "x11"]
             },
             %Dependency{name: "env_logger", version: "0.11"}
           ]},
          {"cfg(target_arch = \"wasm32\")",
           [
             %Dependency{
               name: "eframe",
               version: "0.35",
               default_features: false,
               features: ["default_fonts", "glow", "persistence"]
             },
             %Dependency{name: "log", version: "0.4"},
             %Dependency{
               name: "wasm-bindgen",
               version: "=#{Rekindle.Toolchain.wasm_bindgen_version()}"
             },
             %Dependency{name: "wasm-bindgen-futures", version: "0.4"},
             %Dependency{
               name: "web-sys",
               version: "0.3",
               features: ["Document", "HtmlCanvasElement", "Window"]
             }
           ]}
        ]
      },
      toolchain: "stable",
      web: %Spec.Web{
        graphics: :webgl2,
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
        """
      }
    }
  end
end
