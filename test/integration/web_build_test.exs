defmodule Rekindle.WebBuildTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-web-build-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))
    File.write!(Path.join(root, "client/Cargo.toml"), "[package]\nname = \"fixture_ui\"\n")
    File.write!(Path.join(root, "client/src/bin/web.rs"), "fn main() {}\n")

    Application.put_env(:rekindle_web_build_test, Rekindle,
      integration: :gpui,
      targets: [web: [features: ["web"]]]
    )

    on_exit(fn ->
      Application.delete_env(:rekindle_web_build_test, Rekindle)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "publishes and selects a complete development generation", %{root: root} do
    File.mkdir_p!(Path.join(root, "client/public/images"))
    File.write!(Path.join(root, "client/public/images/icon.txt"), "icon")
    tools = fake_tools(root, "first")

    assert {:ok, first} = build(root, tools)
    generation = first.metadata.generation
    generation_root = Path.dirname(first.artifact)

    assert generation =~ ~r/^[0-9a-f]{32}$/
    assert generation_root == Path.join([root, ".rekindle", "dev", "web", generation])
    assert File.read!(first.artifact) =~ "app_bg.wasm"
    assert File.read!(Path.join(generation_root, "app_bg.wasm")) == "wasm-first"
    assert File.read!(Path.join(generation_root, "images/icon.txt")) == "icon"

    assert read_json(first.metadata.manifest) == %{
             "version" => 1,
             "generation" => generation,
             "entry" => "app.js"
           }

    assert read_json(Path.join(root, ".rekindle/dev/web-current.json")) == %{
             "generation" => generation
           }

    File.write!(tools.mode, "second")
    assert {:ok, second} = build(root, tools)
    assert second.metadata.generation != generation
    assert File.read!(second.artifact) =~ "second"

    File.write!(tools.mode, "third")
    assert {:ok, third} = build(root, tools)

    assert generation_directories(root) ==
             MapSet.new([second.metadata.generation, third.metadata.generation])
  end

  test "publishes release output and updates the selector last", %{root: root} do
    tools = fake_tools(root, "first")
    namespace = Path.join(root, "priv/static/rekindle")
    File.mkdir_p!(namespace)
    File.write!(Path.join(namespace, "keep.txt"), "keep")

    assert {:ok, first} = build(root, tools, profile: :release)
    assert first.artifact =~ "/priv/static/rekindle/web/"
    assert File.read!(Path.join(namespace, "keep.txt")) == "keep"

    refute File.exists?(
             Path.join([root, ".rekindle", "release", "web", first.metadata.generation])
           )

    entry = File.read!(Path.join(namespace, "entry.js"))
    assert entry =~ "// Rekindle generation: #{first.metadata.generation}"
    assert entry =~ ~s(import init from "./web/#{first.metadata.generation}/app.js";)

    File.write!(tools.mode, "second")
    assert {:ok, second} = build(root, tools, profile: :release)
    refute second.metadata.generation == first.metadata.generation
    assert File.read!(Path.join(namespace, "entry.js")) =~ second.metadata.generation
    assert File.regular?(first.artifact)
    assert File.regular?(second.artifact)

    File.write!(tools.mode, "third")
    assert {:ok, third} = build(root, tools, profile: :release)

    assert release_generations(namespace) ==
             MapSet.new([second.metadata.generation, third.metadata.generation])

    refute File.exists?(first.artifact)
    assert File.regular?(second.artifact)
    assert File.regular?(third.artifact)
  end

  test "publishes release output below a configured public directory", %{root: root} do
    Application.put_env(:rekindle_web_build_test, Rekindle,
      integration: :gpui,
      targets: [web: [features: ["web"]]],
      public_dir: "public"
    )

    tools = fake_tools(root, "custom-public-dir")

    assert {:ok, result} = build(root, tools, profile: :release)
    assert result.artifact =~ "/public/rekindle/web/"
    assert File.regular?(Path.join(root, "public/rekindle/entry.js"))
    refute File.exists?(Path.join(root, "priv/static/rekindle"))
  end

  test "does not replace the current selector after an incomplete build", %{root: root} do
    tools = fake_tools(root, "first")
    assert {:ok, selected} = build(root, tools)
    selector = Path.join(root, ".rekindle/dev/web-current.json")
    selected_contents = File.read!(selector)

    File.write!(tools.mode, "missing-entry")

    assert {:error, %Rekindle.Web.Error{kind: :missing_entry}} = build(root, tools)
    assert File.read!(selector) == selected_contents
    assert File.regular?(selected.artifact)
  end

  test "serves ordinary generation files but rejects escaping paths", %{root: root} do
    tools = fake_tools(root, "first")
    assert {:ok, result} = build(root, tools)
    root = Path.dirname(result.artifact)
    manifest = read_json(result.metadata.manifest)

    assert {:ok, "wasm-first"} =
             Rekindle.Web.Manifest.read_member(root, manifest, "app_bg.wasm")

    assert {:error, %Rekindle.Web.Error{kind: :invalid_path}} =
             Rekindle.Web.Manifest.read_member(root, manifest, "../outside")
  end

  test "rejects a public asset that collides with generated output", %{root: root} do
    File.mkdir_p!(Path.join(root, "client/public"))
    File.write!(Path.join(root, "client/public/app.js"), "collision")
    tools = fake_tools(root, "first")

    assert {:error, %Rekindle.Web.Error{kind: :asset_collision}} = build(root, tools)
  end

  defp build(root, tools, options \\ []) do
    Rekindle.build(
      :web,
      [
        otp_app: :rekindle_web_build_test,
        project_root: root,
        cargo: tools.cargo,
        env: tools.env
      ] ++ options
    )
  end

  defp fake_tools(root, mode) do
    mode_path = Path.join(root, "bindgen-mode")
    File.write!(mode_path, mode)

    env = %{
      "HOME" => Path.join(root, "home"),
      "XDG_CACHE_HOME" => Path.join(root, "cache")
    }

    cargo = Path.join(root, "fake-cargo")
    wasm_bindgen = Rekindle.Toolchain.wasm_bindgen_path("0.2.126", env)
    File.mkdir_p!(Path.dirname(wasm_bindgen))
    package_id = "fixture_ui 0.1.0"
    artifact = Path.join(root, "client/target/wasm32-unknown-unknown/debug/web.wasm")

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package_id,
            "name" => "fixture_ui",
            "manifest_path" => Path.join(root, "client/Cargo.toml"),
            "targets" => [
              %{
                "name" => "web",
                "kind" => ["bin"],
                "src_path" => Path.join(root, "client/src/bin/web.rs")
              }
            ],
            "dependencies" => [%{"name" => "gpui"}]
          }
        ],
        "workspace_members" => [package_id],
        "target_directory" => Path.join(root, "client/target")
      })

    compiler_artifact =
      Jason.encode!(%{
        "reason" => "compiler-artifact",
        "package_id" => package_id,
        "target" => %{"name" => "web", "kind" => ["bin"]},
        "filenames" => [artifact],
        "executable" => nil
      })

    write_executable(cargo, """
    #!/bin/sh
    if [ "$1" = "metadata" ]; then
      printf '%s\\n' '#{metadata}'
      exit 0
    fi
    mkdir -p '#{Path.dirname(artifact)}'
    printf 'wasm' > '#{artifact}'
    printf '%s\\n' '#{compiler_artifact}'
    """)

    write_executable(wasm_bindgen, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "wasm-bindgen 0.2.126"
      exit 0
    fi
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--out-dir" ]; then
        output="$2"
        break
      fi
      shift
    done
    mkdir -p "$output"
    mode=$(cat '#{mode_path}')
    if [ "$mode" = "missing-entry" ]; then
      printf 'wasm' > "$output/app_bg.wasm"
      exit 0
    fi
    printf "const wasm = new URL('app_bg.wasm', import.meta.url);\\n/* %s */\\nexport default async function init() { return wasm; }\\n" "$mode" > "$output/app.js"
    printf 'wasm-%s' "$mode" > "$output/app_bg.wasm"
    """)

    %{cargo: cargo, env: env, mode: mode_path}
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp generation_directories(root) do
    root
    |> Path.join(".rekindle/dev/web")
    |> File.ls!()
    |> Enum.filter(&(&1 =~ ~r/^[0-9a-f]{32}$/))
    |> MapSet.new()
  end

  defp release_generations(namespace) do
    namespace
    |> Path.join("web")
    |> File.ls!()
    |> Enum.filter(&(&1 =~ ~r/^[0-9a-f]{32}$/))
    |> MapSet.new()
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()
end
