defmodule Rekindle.ReleaseTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  defmodule Endpoint do
    def static_path(path), do: Process.get({__MODULE__, path})
  end

  test "publishes Phoenix and desktop release artifacts without disturbing sibling files" do
    root = tmp_dir()
    repository = Path.expand("../..", __DIR__)
    tools = write_fixture(root, repository)

    File.mkdir_p!(Path.join(root, "priv/static"))
    File.write!(Path.join(root, "priv/static/sibling.txt"), "web-sibling")
    File.mkdir_p!(Path.join(root, "dist"))
    File.write!(Path.join(root, "dist/sibling.txt"), "desktop-sibling")

    assert {_output, 0} = mix(root, tools, ["deps.get"])

    assert {_output, 0} = mix(root, tools, ["assets.deploy"])

    assert File.read!(tools.order) |> String.split("\n", trim: true) == ["web-release"]

    web_root = Path.join(root, "priv/static/rekindle")
    web_entry_path = Path.join(web_root, "entry.js")
    web_entry = read_entry(web_entry_path)
    web_generation_root = Path.join([web_root, "web", web_entry.generation])
    web_manifest_path = Path.join(web_generation_root, "manifest.json")
    web_manifest = read_json(web_manifest_path)

    canonical_generation_root =
      Path.join([root, ".rekindle/release/web", web_entry.generation])

    canonical_manifest =
      canonical_generation_root
      |> Path.join("manifest.json")
      |> read_json()

    assert web_entry.module == "./web/#{web_entry.generation}/app.js"
    assert File.regular?(Path.join(web_root, String.trim_leading(web_entry.module, "./")))
    assert web_manifest == canonical_manifest
    assert :ok = Rekindle.Web.Manifest.validate(canonical_generation_root, canonical_manifest)

    digest_manifest = read_json(Path.join(root, "priv/static/cache_manifest.json"))
    digested_entry = digest_manifest["latest"]["rekindle/entry.js"]
    assert is_binary(digested_entry)
    Process.put({Endpoint, "/rekindle/entry.js"}, "/" <> digested_entry)
    on_exit(fn -> Process.delete({Endpoint, "/rekindle/entry.js"}) end)

    assert Rekindle.Phoenix.web_entry_path(Endpoint) == "/" <> digested_entry

    for integration <- [:gpui, :egui, :slint] do
      assert is_binary(Rekindle.Phoenix.web_host(integration))
      assert Rekindle.Phoenix.web_entry_path(Endpoint) == "/" <> digested_entry
    end

    assert File.read!(Path.join(root, "priv/static/#{digested_entry}")) ==
             File.read!(web_entry_path)

    assert Enum.any?(digest_manifest["latest"], fn {logical, digested} ->
             logical =~ "rekindle/web/#{web_entry.generation}/" and logical != digested
           end)

    assert File.read!(Path.join(root, "priv/static/sibling.txt")) == "web-sibling"

    assert {_output, 0} = mix(root, tools, ["assets.deploy"])

    assert File.read!(tools.order) |> String.split("\n", trim: true) == [
             "web-release",
             "web-release"
           ]

    repeated_entry = read_entry(web_entry_path)
    repeated_digest_manifest = read_json(Path.join(root, "priv/static/cache_manifest.json"))
    assert repeated_entry == web_entry
    assert is_binary(repeated_digest_manifest["latest"]["rekindle/entry.js"])

    selected_web = File.read!(web_entry_path)
    File.write!(tools.mode, "second")
    File.chmod!(web_root, 0o555)

    {failed_web, status} =
      try do
        mix(root, tools, ["rekindle.build", "web", "--release"])
      after
        File.chmod!(web_root, 0o755)
      end

    assert status != 0
    assert failed_web =~ "cannot update"
    assert File.read!(web_entry_path) == selected_web
    assert File.regular?(Path.join(web_root, String.trim_leading(web_entry.module, "./")))
    assert File.read!(Path.join(root, "priv/static/sibling.txt")) == "web-sibling"

    assert {_output, 0} = mix(root, tools, ["rekindle.build", "desktop", "--release"])
    desktop_root = Path.join([root, "dist", "rekindle", "desktop", tools.target])
    desktop_manifest_path = Path.join(desktop_root, "manifest.json")
    desktop_manifest = read_json(desktop_manifest_path)
    desktop_executable = Path.join(desktop_root, desktop_manifest["executable"])

    assert desktop_manifest["target"] == tools.target
    assert desktop_manifest["integration"] == "gpui"
    assert desktop_manifest["sha256"] == sha256(File.read!(desktop_executable))
    assert executable?(desktop_executable)
    refute File.exists?(tools.launched)
    assert File.read!(Path.join(root, "dist/sibling.txt")) == "desktop-sibling"

    selected_desktop = File.read!(desktop_manifest_path)
    File.write!(tools.mode, "third")
    assert {_output, 0} = mix(root, tools, ["rekindle.build", "desktop"])
    candidate = desktop_candidate(root, tools.target, "third")
    staged = Path.join(desktop_root, "application-#{candidate.manifest["sha256"]}")
    File.cp!(candidate.artifact, staged)
    File.chmod!(staged, 0o755)

    previous = Application.get_env(:release_fixture, Rekindle)

    Application.put_env(:release_fixture, Rekindle,
      integration: :gpui,
      targets: [web: [], desktop: []]
    )

    File.chmod!(desktop_root, 0o555)

    publication =
      try do
        {:ok, project} = Rekindle.Config.load(:release_fixture, project_root: root)
        Rekindle.Desktop.Release.publish(project, candidate.result)
      after
        File.chmod!(desktop_root, 0o755)

        if previous do
          Application.put_env(:release_fixture, Rekindle, previous)
        else
          Application.delete_env(:release_fixture, Rekindle)
        end
      end

    assert {:error, %Rekindle.Desktop.Error{kind: :manifest_write}} = publication
    assert File.read!(desktop_manifest_path) == selected_desktop
    assert File.regular?(desktop_executable)
    refute File.exists?(tools.launched)
    assert File.read!(Path.join(root, "dist/sibling.txt")) == "desktop-sibling"
    assert Path.wildcard(Path.join(root, "priv/static/rekindle/web/.tmp-*")) == []
    assert Path.wildcard(Path.join(desktop_root, ".tmp-*")) == []
  end

  defp write_fixture(root, repository) do
    target = Rekindle.Toolchain.desktop_target()
    mode = Path.join(root, "build-mode")
    order = Path.join(root, "release-order")
    launched = Path.join(root, "desktop-launched")
    bin = Path.join(root, "bin")
    cache = Path.join(root, "cache")
    cargo = Path.join(bin, "cargo")
    rustc = Path.join(bin, "rustc")
    wasm_bindgen = Rekindle.Toolchain.wasm_bindgen_path("0.2.126", %{"XDG_CACHE_HOME" => cache})
    package_id = "release_client 0.1.0"
    web_artifact = Path.join(root, "client/target/wasm32-unknown-unknown/release/web.wasm")
    desktop_artifact = Path.join(root, "client/target/#{target}/release/desktop")

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package_id,
            "name" => "release_client",
            "manifest_path" => Path.join(root, "client/Cargo.toml"),
            "targets" => [
              %{
                "name" => "web",
                "kind" => ["bin"],
                "src_path" => Path.join(root, "client/src/bin/web.rs")
              },
              %{
                "name" => "desktop",
                "kind" => ["bin"],
                "src_path" => Path.join(root, "client/src/bin/desktop.rs")
              }
            ],
            "dependencies" => [%{"name" => "gpui"}]
          }
        ],
        "workspace_members" => [package_id],
        "target_directory" => Path.join(root, "client/target")
      })

    web_message = compiler_message(package_id, "web", web_artifact, nil)
    desktop_message = compiler_message(package_id, "desktop", desktop_artifact, desktop_artifact)

    write(root, "mix.exs", mix_project(repository))
    write(root, "mix.lock", File.read!(Path.join(repository, "mix.lock")))

    write(
      root,
      "config/config.exs",
      """
      import Config

      config :release_fixture, Rekindle,
        integration: :gpui,
        targets: [
          web: [package: "release_client", binary: "web", features: ["web"]],
          desktop: [package: "release_client", binary: "desktop", features: ["desktop"]]
        ]
      """
    )

    write(
      root,
      "client/Cargo.toml",
      "[package]\nname = \"release_client\"\nversion = \"0.1.0\"\n"
    )

    write(root, "client/src/bin/web.rs", "fn main() {}\n")
    write(root, "client/src/bin/desktop.rs", "fn main() {}\n")
    File.write!(mode, "first")

    write_executable(
      cargo,
      """
      #!/bin/sh
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      case " $* " in
        *" --bin web "*)
          mkdir -p '#{Path.dirname(web_artifact)}'
          printf 'web-%s' "$(cat '#{mode}')" > '#{web_artifact}'
          printf 'web-release\\n' >> '#{order}'
          printf '%s\\n' '#{web_message}'
          ;;
        *" --bin desktop "*)
          mkdir -p '#{Path.dirname(desktop_artifact)}'
          printf '#!/bin/sh\\ntouch \"%s\"\\n' '#{launched}' > '#{desktop_artifact}'
          printf '# %s\\n' "$(cat '#{mode}')" >> '#{desktop_artifact}'
          chmod 755 '#{desktop_artifact}'
          printf '%s\\n' '#{desktop_message}'
          ;;
        *)
          exit 64
          ;;
      esac
      """
    )

    write_executable(
      rustc,
      """
      #!/bin/sh
      printf 'rustc 1.90.0\\nhost: #{target}\\n'
      """
    )

    write_executable(
      wasm_bindgen,
      """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        printf 'wasm-bindgen 0.2.126\\n'
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
      current=$(cat '#{mode}')
      printf "const wasm = new URL('app_bg.wasm', import.meta.url);\\nexport default async function init() { return wasm; }\\n" > "$output/app.js"
      printf 'wasm-%s' "$current" > "$output/app_bg.wasm"
      """
    )

    %{bin: bin, cache: cache, launched: launched, mode: mode, order: order, target: target}
  end

  defp mix_project(repository) do
    """
    defmodule ReleaseFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :release_fixture,
          version: "0.1.0",
          elixir: "~> 1.17",
          deps: [
            {:rekindle, path: #{inspect(repository)}},
            {:phoenix, path: #{inspect(Path.join(repository, "deps/phoenix"))}}
          ],
          aliases: ["assets.deploy": ["rekindle.build web --release", "phx.digest"]]
        ]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  defp mix(root, tools, arguments) do
    environment = [
      {"PATH", tools.bin <> ":" <> System.fetch_env!("PATH")},
      {"XDG_CACHE_HOME", tools.cache},
      {"MIX_DEPS_PATH", Path.join(root, "deps")},
      {"MIX_BUILD_PATH", Path.join(root, "_build")}
    ]

    System.cmd("mix", arguments, cd: root, env: environment, stderr_to_stdout: true)
  end

  defp desktop_candidate(root, target, marker) do
    root
    |> Path.join(".rekindle/dev/desktop/#{target}/*/manifest.json")
    |> Path.wildcard()
    |> Enum.find_value(fn manifest_path ->
      manifest = read_json(manifest_path)
      artifact = Path.join(Path.dirname(manifest_path), manifest["executable"])

      if File.read!(artifact) =~ "# #{marker}" do
        %{
          artifact: artifact,
          manifest: manifest,
          result: %Rekindle.Build.Result{
            target: :desktop,
            profile: :release,
            artifact: artifact,
            metadata: %{
              generation: manifest["generation"],
              manifest: manifest_path,
              rust_target: target
            }
          }
        }
      end
    end) || flunk("missing desktop candidate for #{marker}")
  end

  defp compiler_message(package_id, binary, artifact, executable) do
    Jason.encode!(%{
      "reason" => "compiler-artifact",
      "package_id" => package_id,
      "target" => %{"name" => binary, "kind" => ["bin"]},
      "filenames" => [artifact],
      "executable" => executable
    })
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp write_executable(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp read_entry(path) do
    contents = File.read!(path)

    assert [generation, module] =
             Regex.run(
               ~r/\A\/\/ Rekindle generation: ([0-9a-f]{64})\nimport init from "([^"]+)";\nawait init\(\);\n\z/,
               contents,
               capture: :all_but_first
             )

    %{generation: generation, module: module}
  end

  defp executable?(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o111) != 0
  end

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-release-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
