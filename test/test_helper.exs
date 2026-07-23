ExUnit.start()

defmodule Rekindle.CompatibilityFixture do
  alias Rekindle.Toolchain.{CompatibilityManifest, Helper}

  def release(asset) do
    template = %{"version" => "0.1.0", "manifest_sha256" => String.duplicate("d", 64)}

    helper = %{
      "protocol_digest" => Helper.protocol_digest(),
      "asset_sha256" => asset["sha256"]
    }

    gpui = %{
      "source" => "https://github.com/zed-industries/zed",
      "revision" => String.duplicate("a", 40)
    }

    host = Map.take(asset, ~w[os arch target_triple])

    base = %{
      "v" => 1,
      "rekindle_version" => "0.1.0",
      "elixir" => "1.20.2",
      "otp" => "28.0.0",
      "phoenix" => "1.8.9",
      "igniter" => "0.8.2",
      "host" => host,
      "gpui" => gpui,
      "helper" => helper,
      "client_template" => template
    }

    web =
      Map.merge(base, %{
        "endpoint_adapter" => %{"name" => "bandit", "version" => "1.12.0"},
        "target" => "web",
        "rust" => %{
          "toolchain" => "nightly-2026-04-01",
          "components" => ["rust-src"],
          "targets" => ["wasm32-unknown-unknown"]
        },
        "wasm_bindgen" => "0.2.121",
        "browser" => %{
          "family" => "chromium",
          "version" => "140.0.0",
          "secure_context" => true,
          "webgpu" => true
        }
      })
      |> with_tuple_id()

    desktop =
      Map.merge(base, %{
        "endpoint_adapter" => nil,
        "target" => "desktop",
        "rust" => %{"toolchain" => "1.95.0", "components" => [], "targets" => []},
        "wasm_bindgen" => nil,
        "browser" => nil
      })
      |> with_tuple_id()

    tuples = Enum.sort_by([web, desktop], & &1["tuple_id"])

    %{
      "contract_version" => 1,
      "rekindle_version" => "0.1.0",
      "elixir" => range("1.17.0", "2.0.0", ["1.20.2"]),
      "otp" => range("27.0.0", "29.0.0", ["28.0.0"]),
      "phoenix" => range("1.8.0", "1.9.0", ["1.8.9"]),
      "endpoint_adapters" => [
        Map.put(range("1.12.0", "2.0.0", ["1.12.0"]), "name", "bandit")
      ],
      "igniter" => range("0.8.0", "0.9.0", ["0.8.2"]),
      "targets" => %{
        "web" => %{
          "rust_toolchain" => "nightly-2026-04-01",
          "rust_components" => ["rust-src"],
          "rust_targets" => ["wasm32-unknown-unknown"],
          "wasm_bindgen" => "0.2.121",
          "gpui_source" => gpui["source"],
          "gpui_revision" => gpui["revision"],
          "browsers" => [%{"family" => "chromium", "version" => "140.0.0"}],
          "secure_context" => true,
          "webgpu" => true
        },
        "desktop" => %{
          "rust_toolchain" => "1.95.0",
          "gpui_source" => gpui["source"],
          "gpui_revision" => gpui["revision"],
          "hosts" => [host]
        }
      },
      "helper" => %{
        "protocol" => Helper.compatibility(),
        "protocol_digest" => Helper.protocol_digest(),
        "assets" => [asset]
      },
      "client_template" => %{
        "version" => template["version"],
        "rekindle_client" => "0.1.0",
        "manifest_sha256" => template["manifest_sha256"]
      },
      "tuples" => tuples,
      "evidence" =>
        Enum.map(tuples, fn tuple ->
          %{
            "tuple_id" => tuple["tuple_id"],
            "ci_job" => "qualify-#{tuple["target"]}",
            "source_revision" => String.duplicate("c", 40)
          }
        end)
        |> Enum.sort_by(&{&1["tuple_id"], &1["ci_job"]})
    }
  end

  def encode(asset), do: asset |> release() |> CompatibilityManifest.encode_release!()

  defp range(min, max, tested),
    do: %{"min" => min, "max_exclusive" => max, "tested" => tested}

  defp with_tuple_id(tuple),
    do: Map.put(tuple, "tuple_id", CompatibilityManifest.tuple_id(tuple))
end
