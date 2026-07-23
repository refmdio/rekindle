defmodule Rekindle.DesktopBuildTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:rekindle_desktop_build_test, Rekindle)

    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-desktop-build-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))
    File.write!(Path.join(root, "client/Cargo.toml"), "[package]\nname = \"fixture_ui\"\n")
    File.write!(Path.join(root, "client/src/bin/desktop.rs"), "fn main() {}\n")

    Application.put_env(:rekindle_desktop_build_test, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    on_exit(fn ->
      File.rm_rf!(root)

      if previous do
        Application.put_env(:rekindle_desktop_build_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_desktop_build_test, Rekindle)
      end
    end)

    %{root: root}
  end

  test "publishes an executable without launching it", %{root: root} do
    tools = fake_tools(root, executable?: true)

    assert {:ok, %Rekindle.Build.Result{} = result} = build(root, tools)
    assert result.target == :desktop
    assert result.profile == :dev
    assert result.metadata.rust_target == tools.target
    refute File.exists?(tools.launched)

    generation = result.metadata.generation
    generation_root = Path.dirname(result.artifact)

    assert generation =~ ~r/^[0-9a-f]{64}$/

    assert generation_root ==
             Path.join([root, ".rekindle", "dev", "desktop", tools.target, generation])

    assert executable?(result.artifact)

    manifest = result.metadata.manifest |> File.read!() |> Jason.decode!()
    assert manifest["generation"] == generation
    assert manifest["target"] == tools.target
    assert manifest["package"] == "fixture_ui"
    assert manifest["binary"] == "desktop"
    assert manifest["executable"] == "desktop"
    assert manifest["sha256"] == sha256(File.read!(result.artifact))

    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-current.json"))
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-last-running.json"))
    assert Path.wildcard(Path.join(root, ".rekindle/tmp/desktop/*")) == []

    assert {:ok, second} = build(root, tools)
    assert second.artifact == result.artifact
    refute File.exists?(tools.launched)
  end

  test "keeps release and development generations separate", %{root: root} do
    tools = fake_tools(root, executable?: true)

    assert {:ok, result} = build(root, tools, profile: :release)
    assert result.profile == :release
    assert result.artifact =~ "/.rekindle/release/desktop/#{tools.target}/"
    refute File.exists?(Path.join(root, ".rekindle/release/desktop-current.json"))
    refute File.exists?(Path.join(root, ".rekindle/release/desktop-last-running.json"))
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-current.json"))
    refute File.exists?(tools.launched)
  end

  test "rejects changed bytes in an existing generation", %{root: root} do
    tools = fake_tools(root, executable?: true)
    assert {:ok, result} = build(root, tools)

    File.write!(result.artifact, "changed")
    File.chmod!(result.artifact, 0o755)

    assert {:error, %Rekindle.Desktop.Error{kind: :executable_hash}} = build(root, tools)
    assert File.read!(result.artifact) == "changed"
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-last-running.json"))
    assert Path.wildcard(Path.join(root, ".rekindle/tmp/desktop/*")) == []
  end

  test "rejects non-executable Cargo output", %{root: root} do
    tools = fake_tools(root, executable?: false)

    assert {:error, %Rekindle.Desktop.Error{kind: :not_executable}} = build(root, tools)
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-current.json"))
  end

  test "reports publication state failures without leaving a selector", %{root: root} do
    tools = fake_tools(root, executable?: true)
    File.mkdir_p!(Path.join(root, ".rekindle"))
    File.write!(Path.join(root, ".rekindle/dev"), "not a directory")

    assert {:error, %Rekindle.Desktop.Error{kind: :mkdir}} = build(root, tools)
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-current.json"))
  end

  test "validates manifest identity and target paths", %{root: root} do
    tools = fake_tools(root, executable?: true)
    assert {:ok, result} = build(root, tools)
    generation_root = Path.dirname(result.artifact)
    manifest = result.metadata.manifest |> File.read!() |> Jason.decode!()

    changed_target = %{manifest | "target" => "other-target"}

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate(generation_root, changed_target)

    escaping = %{manifest | "target" => "../outside"}

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate(generation_root, escaping)
  end

  defp build(root, tools, options \\ []) do
    Rekindle.build(
      :desktop,
      [
        otp_app: :rekindle_desktop_build_test,
        project_root: root,
        cargo: tools.cargo,
        rustc: tools.rustc
      ] ++ options
    )
  end

  defp fake_tools(root, options) do
    target = "x86_64-fixture-linux-gnu"
    launched = Path.join(root, "launched")
    artifact = Path.join(root, "client/target/#{target}/debug/desktop")
    rustc = Path.join(root, "fake-rustc")
    cargo = Path.join(root, "fake-cargo")
    package_id = "fixture_ui 0.1.0"

    write_executable(
      rustc,
      """
      #!/bin/sh
      printf 'rustc 1.90.0\\nhost: #{target}\\n'
      """
    )

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package_id,
            "name" => "fixture_ui",
            "manifest_path" => Path.join(root, "client/Cargo.toml"),
            "targets" => [
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

    compiler_artifact =
      Jason.encode!(%{
        "reason" => "compiler-artifact",
        "package_id" => package_id,
        "target" => %{"name" => "desktop", "kind" => ["bin"]},
        "filenames" => [artifact],
        "executable" => artifact
      })

    mode = if options[:executable?], do: "755", else: "644"

    write_executable(
      cargo,
      """
      #!/bin/sh
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      mkdir -p '#{Path.dirname(artifact)}'
      printf '#!/bin/sh\\ntouch \"%s\"\\n' '#{launched}' > '#{artifact}'
      chmod #{mode} '#{artifact}'
      printf '%s\\n' '#{compiler_artifact}'
      """
    )

    %{cargo: cargo, rustc: rustc, target: target, launched: launched}
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp executable?(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o111) != 0
  end

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
