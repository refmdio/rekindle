defmodule Rekindle.WebBuildTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:rekindle_web_build_test, Rekindle)

    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-web-build-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))
    File.write!(Path.join(root, "client/Cargo.toml"), "[package]\nname = \"fixture_ui\"\n")
    File.write!(Path.join(root, "client/src/bin/web.rs"), "fn main() {}\n")

    Application.put_env(:rekindle_web_build_test, Rekindle,
      integration: :gpui,
      targets: [web: [features: ["web"]]]
    )

    on_exit(fn ->
      File.rm_rf!(root)

      if previous do
        Application.put_env(:rekindle_web_build_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_web_build_test, Rekindle)
      end
    end)

    %{root: root}
  end

  test "publishes a complete immutable Web generation", %{root: root} do
    File.mkdir_p!(Path.join(root, "client/public/images"))
    File.write!(Path.join(root, "client/public/images/icon.txt"), "icon")
    tools = fake_tools(root, "success")

    assert {:ok, %Rekindle.Build.Result{} = result} = build(root, tools)
    assert result.target == :web
    assert result.profile == :dev
    assert File.regular?(result.artifact)

    generation = result.metadata.generation
    generation_root = Path.dirname(result.artifact)

    assert generation =~ ~r/^[0-9a-f]{64}$/
    assert generation_root == Path.join([root, ".rekindle", "dev", "web", generation])
    assert File.read!(result.artifact) =~ "app_bg.wasm"
    assert File.read!(Path.join(generation_root, "images/icon.txt")) == "icon"

    manifest = generation_root |> Path.join("manifest.json") |> read_json()
    assert manifest["generation"] == generation
    assert manifest["entry"] == "app.js"

    assert Enum.map(manifest["members"], & &1["path"]) == [
             "app.js",
             "app_bg.wasm",
             "images/icon.txt",
             "snippets/helper.js"
           ]

    Enum.each(manifest["members"], fn member ->
      contents = File.read!(Path.join(generation_root, member["path"]))
      assert member["sha256"] == sha256(contents)
    end)

    selector = root |> Path.join(".rekindle/dev/web-current.json") |> read_json()
    assert selector["generation"] == generation
    assert selector["manifest"] == "web/#{generation}/manifest.json"
    assert Path.wildcard(Path.join(root, ".rekindle/tmp/web/*")) == []

    assert {:ok, second} = build(root, tools)
    assert second.artifact == result.artifact
    assert File.read!(result.artifact) =~ "app_bg.wasm"
  end

  test "publishes release output separately from development output", %{root: root} do
    tools = fake_tools(root, "success")

    assert {:ok, result} = build(root, tools, profile: :release)
    assert result.profile == :release
    assert result.artifact =~ "/priv/static/rekindle/web/"
    assert File.regular?(result.artifact)

    entry = root |> Path.join("priv/static/rekindle/entry.js") |> read_entry()
    assert entry.generation == result.metadata.generation
    assert entry.module == "./web/#{result.metadata.generation}/app.js"

    assert result.metadata.manifest ==
             Path.join([
               root,
               "priv/static/rekindle/web",
               result.metadata.generation,
               "manifest.json"
             ])

    assert File.regular?(
             Path.join([
               root,
               ".rekindle/release/web",
               result.metadata.generation,
               "manifest.json"
             ])
           )

    refute File.exists?(Path.join(root, ".rekindle/dev/web-current.json"))
    refute File.exists?(Path.join(root, ".rekindle/release/web-current.json"))
    refute File.exists?(Path.join(root, "priv/static/rekindle/web-current.json"))
  end

  test "retains the selected and previous Web releases without removing sibling files", %{
    root: root
  } do
    tools = fake_tools(root, "success-one")
    namespace = Path.join(root, "priv/static/rekindle")
    File.mkdir_p!(Path.join(namespace, "web"))
    File.write!(Path.join(namespace, "keep.txt"), "application-owned")
    File.mkdir_p!(Path.join(namespace, "web/.tmp-stale"))

    assert {:ok, first} = build(root, tools, profile: :release)
    refute File.exists?(Path.join(namespace, "web/.tmp-stale"))

    File.write!(tools.mode, "success-two")
    assert {:ok, second} = build(root, tools, profile: :release)

    File.write!(tools.mode, "success-three")
    assert {:ok, third} = build(root, tools, profile: :release)

    generations =
      namespace
      |> Path.join("web")
      |> File.ls!()
      |> Enum.filter(&(&1 =~ ~r/^[0-9a-f]{64}$/))
      |> MapSet.new()

    assert generations ==
             MapSet.new([second.metadata.generation, third.metadata.generation])

    refute MapSet.member?(generations, first.metadata.generation)
    assert File.read!(Path.join(namespace, "keep.txt")) == "application-owned"
  end

  test "rejects a missing or changed manifest in an existing public generation", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools, profile: :release)

    entry_path = Path.join(root, "priv/static/rekindle/entry.js")
    entry = File.read!(entry_path)
    manifest_path = result.metadata.manifest
    manifest = File.read!(manifest_path)
    artifact = File.read!(result.artifact)

    File.write!(manifest_path, Jason.encode!(%{"generation" => result.metadata.generation}))

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             build(root, tools, profile: :release)

    assert File.read!(entry_path) == entry

    File.write!(manifest_path, manifest)
    File.write!(result.artifact, "changed")

    assert {:error, %Rekindle.Web.Error{kind: :member_hash}} =
             build(root, tools, profile: :release)

    assert File.read!(entry_path) == entry

    File.write!(result.artifact, artifact)
    File.rm!(manifest_path)

    assert {:error, %Rekindle.Web.Error{kind: :manifest_read}} =
             build(root, tools, profile: :release)

    assert File.read!(entry_path) == entry
  end

  test "rolls back a new generation when the release selector cannot be replaced", %{
    root: root
  } do
    tools = fake_tools(root, "success-one")
    assert {:ok, first} = build(root, tools, profile: :release)

    namespace = Path.join(root, "priv/static/rekindle")
    entry = Path.join(namespace, "entry.js")
    selected = File.read!(entry)

    File.write!(tools.mode, "success-two")
    assert {:ok, candidate} = build(root, tools)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    destination =
      Path.join([
        namespace,
        "web",
        candidate.metadata.generation
      ])

    File.chmod!(namespace, 0o555)

    publication =
      try do
        Rekindle.Web.Release.publish(project, %{candidate | profile: :release})
      after
        File.chmod!(namespace, 0o755)
      end

    assert {:error, %Rekindle.Web.Error{kind: :selector_write}} = publication
    assert File.read!(entry) == selected
    assert File.regular?(first.artifact)
    refute File.exists?(destination)
  end

  test "serializes concurrent Web releases in the same public namespace", %{root: root} do
    tools = fake_tools(root, "success-one")
    assert {:ok, first} = build(root, tools)

    File.write!(tools.mode, "success-two")
    assert {:ok, second} = build(root, tools)

    File.write!(tools.mode, "success-three")
    assert {:ok, third} = build(root, tools)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    parent = self()
    namespace = Path.join(root, "priv/static/rekindle")

    holder =
      Task.async(fn ->
        Rekindle.Publication.with_lock(root, :web_release, fn ->
          send(parent, :publication_locked)

          receive do
            :release_publication -> :ok
          end
        end)
      end)

    assert_receive :publication_locked

    tasks =
      for candidate <-
            List.duplicate(first, 4) ++
              List.duplicate(second, 4) ++
              List.duplicate(third, 4) do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :publish -> Rekindle.Web.Release.publish(project, %{candidate | profile: :release})
          end
        end)
      end

    pids =
      for _index <- 1..length(tasks) do
        assert_receive {:ready, pid}
        pid
      end

    try do
      Enum.each(pids, &send(&1, :publish))
      Enum.each(tasks, &assert(Task.yield(&1, 50) == nil))
    after
      send(holder.pid, :release_publication)
      assert :ok = Task.await(holder)
    end

    assert Enum.all?(tasks, fn task ->
             match?({:ok, %Rekindle.Build.Result{}}, Task.await(task, 10_000))
           end)

    entry = namespace |> Path.join("entry.js") |> read_entry()
    generation_root = Path.join([namespace, "web", entry.generation])
    manifest = generation_root |> Path.join("manifest.json") |> read_json()

    assert File.regular?(Path.join(namespace, String.trim_leading(entry.module, "./")))
    assert File.regular?(Path.join(generation_root, "manifest.json"))
    assert :ok = Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert namespace
           |> Path.join("web")
           |> File.ls!()
           |> Enum.count(&(&1 =~ ~r/^[0-9a-f]{64}$/)) <= 2
  end

  test "keeps the selected generation when the next package is incomplete", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools)
    selector = Path.join(root, ".rekindle/dev/web-current.json")
    selected = File.read!(selector)

    File.write!(tools.mode, "missing-reference")

    assert {:error, %Rekindle.Web.Error{kind: :missing_reference}} = build(root, tools)
    assert File.read!(selector) == selected
    assert File.regular?(result.artifact)
    assert Path.wildcard(Path.join(root, ".rekindle/tmp/web/*")) == []
  end

  test "does not select a generation pruned by another activation", %{root: root} do
    tools = fake_tools(root, "success-one")

    candidates =
      for {mode, second} <-
            Enum.zip(["success-one", "success-two", "success-three"], [1, 2, 3]) do
        File.write!(tools.mode, mode)
        assert {:ok, candidate} = build(root, tools, activate: false)
        File.touch!(Path.dirname(candidate.artifact), {{2026, 1, 1}, {0, 0, second}})
        candidate
      end

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    assert :ok = Rekindle.Web.Builder.activate(project, Enum.at(candidates, 0))
    refute File.exists?(Enum.at(candidates, 1).artifact)
    assert File.exists?(Enum.at(candidates, 2).artifact)

    selector_path = Path.join(root, ".rekindle/dev/web-current.json")
    selected = File.read!(selector_path)

    assert {:error, %Rekindle.Web.Error{kind: :manifest_read}} =
             Rekindle.Web.Builder.activate(project, Enum.at(candidates, 1))

    assert File.read!(selector_path) == selected

    selected_generation = read_json(selector_path)["generation"]
    assert File.dir?(Path.join([root, ".rekindle", "dev", "web", selected_generation]))
  end

  test "rejects an unlisted member when reusing a development generation", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools)

    generation_root = Path.dirname(result.artifact)
    manifest = generation_root |> Path.join("manifest.json") |> read_json()
    selector_path = Path.join(root, ".rekindle/dev/web-current.json")
    selected = File.read!(selector_path)

    File.write!(Path.join(generation_root, "unlisted.txt"), "unlisted")

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} = build(root, tools)
    assert File.read!(selector_path) == selected
  end

  test "rejects an unlisted member when reusing a release build generation", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools, profile: :release)

    selector_path = Path.join(root, "priv/static/rekindle/entry.js")
    selected = File.read!(selector_path)

    generation_root =
      Path.join([root, ".rekindle/release/web", result.metadata.generation])

    manifest = generation_root |> Path.join("manifest.json") |> read_json()
    File.write!(Path.join(generation_root, "unlisted.txt"), "unlisted")

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             build(root, tools, profile: :release)

    assert File.read!(selector_path) == selected
  end

  test "reports incomplete and failed wasm-bindgen output", %{root: root} do
    tools = fake_tools(root, "missing-entry")

    assert {:error, %Rekindle.Web.Error{kind: :missing_entry}} = build(root, tools)

    File.write!(tools.mode, "failure")

    assert {:error, %Rekindle.Web.Error{kind: :wasm_bindgen, output: output}} =
             build(root, tools)

    assert output =~ "bindgen failed"
    refute File.exists?(Path.join(root, ".rekindle/dev/web-current.json"))
  end

  test "rejects disabled and missing Web entries before running tools", %{root: root} do
    tools = fake_tools(root, "failure")

    Application.put_env(:rekindle_web_build_test, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    assert {:error, %Rekindle.Build.Error{kind: :disabled_target}} = build(root, tools)

    Application.put_env(:rekindle_web_build_test, Rekindle,
      integration: :gpui,
      targets: [web: []]
    )

    File.rm!(Path.join(root, "client/src/bin/web.rs"))
    assert {:error, %Rekindle.Build.Error{kind: :missing_entry}} = build(root, tools)
  end

  test "rejects public collisions and symbolic links", %{root: root} do
    tools = fake_tools(root, "success")
    File.mkdir_p!(Path.join(root, "client/public"))
    File.write!(Path.join(root, "client/public/app.js"), "collision")

    assert {:error, %Rekindle.Web.Error{kind: :asset_collision}} = build(root, tools)

    File.rm!(Path.join(root, "client/public/app.js"))
    File.ln_s!("elsewhere", Path.join(root, "client/public/link"))

    assert {:error, %Rekindle.Web.Error{kind: :copy_public}} = build(root, tools)
  end

  test "reports publication state failures without leaving a selector", %{root: root} do
    tools = fake_tools(root, "success")
    File.mkdir_p!(Path.join(root, ".rekindle"))
    File.write!(Path.join(root, ".rekindle/dev"), "not a directory")

    assert {:error, %Rekindle.Web.Error{kind: :mkdir}} = build(root, tools)
    refute File.exists?(Path.join(root, ".rekindle/dev/web-current.json"))
  end

  test "detects changed, duplicate, and escaping manifest members", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools)
    generation_root = Path.dirname(result.artifact)
    manifest = generation_root |> Path.join("manifest.json") |> read_json()
    original = File.read!(result.artifact)
    selector = File.read!(Path.join(root, ".rekindle/dev/web-current.json"))

    File.write!(result.artifact, "changed")

    assert {:error, %Rekindle.Web.Error{kind: :member_hash}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :member_hash}} = build(root, tools)
    assert File.read!(Path.join(root, ".rekindle/dev/web-current.json")) == selector

    File.write!(result.artifact, original)
    File.rm!(result.artifact)
    File.ln_s!("snippets/helper.js", result.artifact)

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    File.rm!(result.artifact)
    File.write!(result.artifact, original)
    duplicate = update_in(manifest["members"], &(&1 ++ [hd(&1)]))

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, duplicate)

    escaping =
      put_in(
        manifest["members"],
        [%{"path" => "../outside.js", "sha256" => sha256("outside")} | manifest["members"]]
      )

    assert {:error, %Rekindle.Web.Error{kind: :invalid_path}} =
             Rekindle.Web.Manifest.validate(generation_root, escaping)
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

    write_executable(
      cargo,
      """
      #!/bin/sh
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      mkdir -p '#{Path.dirname(artifact)}'
      printf 'wasm' > '#{artifact}'
      printf '%s\\n' '#{compiler_artifact}'
      """
    )

    write_executable(
      wasm_bindgen,
      """
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
      case "$mode" in
        success*)
          mkdir -p "$output/snippets"
          printf "/* %s */\\nimport './snippets/helper.js';\\nconst imports = {'./app_bg.js': {}};\\nconst wasm = new URL('app_bg.wasm', import.meta.url);\\nexport default async function init() { return wasm; }\\n" "$mode" > "$output/app.js"
          printf 'wasm-%s' "$mode" > "$output/app_bg.wasm"
          printf 'export const mode = "%s";\\n' "$mode" > "$output/snippets/helper.js"
          ;;
        missing-reference)
          printf "const wasm = new URL('app_bg.wasm', import.meta.url);\\n" > "$output/app.js"
          ;;
        missing-entry)
          printf 'wasm' > "$output/app_bg.wasm"
          ;;
        failure)
          echo "bindgen failed" >&2
          exit 17
          ;;
      esac
      """
    )

    %{cargo: cargo, env: env, mode: mode_path}
  end

  defp write_executable(path, contents) do
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

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
