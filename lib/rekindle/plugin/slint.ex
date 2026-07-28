defmodule Rekindle.Plugin.Slint do
  @moduledoc "Built-in Slint support."

  @behaviour Rekindle.Plugin

  alias Rekindle.Plugin.{Cargo, Spec}
  alias Rekindle.Plugin.Cargo.Dependency

  @impl true
  def name, do: "slint"

  @impl true
  def spec(_options) do
    %Spec{
      name: name(),
      dependency: "slint",
      source: {:rekindle, "templates/client/slint"},
      files: %{
        "Cargo.lock" => "Cargo.lock",
        "build.rs" => "build.rs",
        "src/lib.rs" => "src/lib.rs",
        "ui/app-window.slint" => "ui/app-window.slint"
      },
      entries: %{
        web: "src/bin/web.rs",
        desktop: "src/bin/desktop.rs"
      },
      cargo: %Cargo{
        dependencies: [],
        target_dependencies: [
          {"cfg(not(target_arch = \"wasm32\"))",
           [
             %Dependency{name: "slint", version: "=1.16.1"}
           ]},
          {"cfg(target_arch = \"wasm32\")",
           [
             %Dependency{name: "i-slint-backend-winit", version: "=1.16.1"},
             %Dependency{
               name: "slint",
               version: "=1.16.1",
               default_features: false,
               features: ["compat-1-2", "renderer-femtovg", "backend-winit", "std"]
             },
             %Dependency{
               name: "wasm-bindgen",
               version: "=#{Rekindle.Toolchain.wasm_bindgen_version()}"
             }
           ]}
        ],
        build_dependencies: [
          %Dependency{name: "slint-build", version: "=1.16.1"}
        ]
      },
      toolchain: "stable",
      web: %Spec.Web{
        graphics: :webgl2,
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
        """
      }
    }
  end
end
