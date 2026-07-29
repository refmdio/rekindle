defmodule Rekindle.Plugin.GPUI do
  @moduledoc "Built-in GPUI support."

  @behaviour Rekindle.Plugin

  alias Rekindle.Plugin.{Cargo, Spec}
  alias Rekindle.Plugin.Cargo.Dependency

  @zed_revision "18f35ffac2da72ccdfb0e1bf756218fa1995162b"

  @impl true
  def name, do: "gpui"

  @impl true
  def spec(_options) do
    %Spec{
      name: name(),
      dependency: "gpui",
      source: {:rekindle, "templates/client/gpui"},
      files: %{
        "Cargo.lock" => "Cargo.lock",
        "src/lib.rs" => "src/lib.rs"
      },
      entries: %{
        web: "src/bin/web.rs",
        desktop: "src/bin/desktop.rs"
      },
      cargo: %Cargo{
        dependencies: [
          %Dependency{
            name: "gpui",
            git: "https://github.com/zed-industries/zed",
            rev: @zed_revision
          },
          %Dependency{
            name: "gpui_platform",
            git: "https://github.com/zed-industries/zed",
            rev: @zed_revision,
            features: ["wayland", "x11"]
          }
        ],
        dev_dependencies: [
          %Dependency{
            name: "gpui",
            git: "https://github.com/zed-industries/zed",
            rev: @zed_revision,
            features: ["test-support"]
          }
        ],
        target_dependencies: [
          {"cfg(target_arch = \"wasm32\")",
           [
             %Dependency{
               name: "wasm-bindgen",
               version: "=#{Rekindle.Toolchain.wasm_bindgen_version()}"
             }
           ]}
        ],
        profiles: [
          {"dev", debug: "limited"},
          {"release", lto: "thin"}
        ]
      },
      toolchain: "nightly",
      web: %Spec.Web{
        graphics: :webgpu,
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
        """
      }
    }
  end
end
