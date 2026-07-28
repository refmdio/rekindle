defmodule Rekindle.Plugin.Iced do
  @moduledoc "Built-in Iced support."

  @behaviour Rekindle.Plugin

  alias Rekindle.Plugin.{Cargo, Spec}
  alias Rekindle.Plugin.Cargo.Dependency

  @impl true
  def name, do: "iced"

  @impl true
  def spec(_options) do
    %Spec{
      name: name(),
      dependency: "iced",
      source: {:rekindle, "templates/client/iced"},
      files: %{
        "Cargo.lock" => "Cargo.lock",
        "src/lib.rs" => "src/lib.rs"
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
             %Dependency{name: "iced", version: "=0.14.0"}
           ]},
          {"cfg(target_arch = \"wasm32\")",
           [
             %Dependency{
               name: "iced",
               version: "=0.14.0",
               default_features: false,
               features: ["wgpu", "webgl", "fira-sans"]
             },
             %Dependency{
               name: "wasm-bindgen",
               version: "=#{Rekindle.Toolchain.wasm_bindgen_version()}"
             }
           ]}
        ]
      },
      toolchain: "stable",
      web: %Spec.Web{
        graphics: :webgl2,
        host: "",
        style: """
        * {
          box-sizing: border-box;
        }

        html,
        body {
          overflow: hidden;
          margin: 0;
          padding: 0;
          width: 100%;
          height: 100%;
        }

        body > canvas {
          display: block;
          width: 100%;
          height: 100%;
          touch-action: none;
          outline: none;
        }
        """
      }
    }
  end
end
