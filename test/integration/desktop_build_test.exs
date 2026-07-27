defmodule Rekindle.DesktopBuildTest do
  use ExUnit.Case, async: false

  setup do
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
      Application.delete_env(:rekindle_desktop_build_test, Rekindle)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "stages a development executable without launching it", %{root: root} do
    tools = fake_tools(root, "first")

    assert {:ok, first} = build(root, tools)
    assert first.target == :desktop
    assert first.profile == :dev
    assert Path.basename(first.artifact) == "application"
    assert executable?(first.artifact)
    refute File.exists?(tools.launched)

    manifest = read_json(first.metadata.manifest)

    assert manifest == %{
             "version" => 1,
             "target" => tools.target,
             "package" => "fixture_ui",
             "binary" => "desktop",
             "integration" => "gpui",
             "executable" => "application"
           }

    assert :ok = Rekindle.Desktop.Manifest.validate(Path.dirname(first.artifact), manifest)

    assert {:ok, second} = build(root, tools)
    assert second.artifact != first.artifact
    assert File.regular?(first.artifact)
    assert File.regular?(second.artifact)
  end

  test "publishes a fixed release layout and preserves sibling files", %{root: root} do
    tools = fake_tools(root, "first")
    destination = Path.join([root, "dist", "rekindle", "desktop", tools.target])
    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "keep.txt"), "keep")

    assert {:ok, first} = build(root, tools, profile: :release)
    assert first.artifact == Path.join(destination, "application")
    assert first.metadata.manifest == Path.join(destination, "manifest.json")
    assert File.read!(first.artifact) =~ "# first"
    assert File.read!(Path.join(destination, "keep.txt")) == "keep"
    refute File.exists?(tools.launched)

    File.write!(tools.mode, "second")
    assert {:ok, second} = build(root, tools, profile: :release)
    assert second.artifact == first.artifact
    assert File.read!(second.artifact) =~ "# second"
    assert File.read!(Path.join(destination, "keep.txt")) == "keep"
  end

  test "rejects an invalid manifest or non-executable artifact", %{root: root} do
    directory = Path.join(root, "manifest")
    File.mkdir!(directory)
    executable = Path.join(directory, "application")
    File.write!(executable, "not executable")

    fields = %{
      "version" => 1,
      "target" => "x86_64-unknown-linux-gnu",
      "package" => "fixture_ui",
      "binary" => "desktop",
      "integration" => "gpui",
      "executable" => "application"
    }

    assert {:error, %Rekindle.Desktop.Error{kind: :not_executable}} =
             Rekindle.Desktop.Manifest.validate(directory, fields)

    File.chmod!(executable, 0o755)
    assert :ok = Rekindle.Desktop.Manifest.validate(directory, fields)

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate(directory, Map.put(fields, "extra", true))
  end

  test "reports a Cargo artifact that is not executable", %{root: root} do
    tools = fake_tools(root, "invalid", executable?: false)

    assert {:error, %Rekindle.Desktop.Error{kind: :not_executable}} =
             build(root, tools)
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

  defp fake_tools(root, marker, options \\ []) do
    {:ok, target} = Rekindle.Toolchain.host_target()
    launched = Path.join(root, "launched")
    mode = Path.join(root, "desktop-mode")
    artifact = Path.join(root, "client/target/#{target}/debug/desktop")
    rustc = Path.join(root, "fake-rustc")
    cargo = Path.join(root, "fake-cargo")
    package_id = "fixture_ui 0.1.0"
    File.write!(mode, marker)

    write_executable(rustc, """
    #!/bin/sh
    printf 'rustc 1.90.0\\nhost: #{target}\\n'
    """)

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

    chmod = if Keyword.get(options, :executable?, true), do: "755", else: "644"

    write_executable(cargo, """
    #!/bin/sh
    if [ "$1" = "metadata" ]; then
      printf '%s\\n' '#{metadata}'
      exit 0
    fi
    mkdir -p '#{Path.dirname(artifact)}'
    printf '#!/bin/sh\\ntouch "#{launched}"\\n# %s\\n' "$(cat '#{mode}')" > '#{artifact}'
    chmod #{chmod} '#{artifact}'
    printf '%s\\n' '#{compiler_artifact}'
    """)

    %{cargo: cargo, rustc: rustc, target: target, launched: launched, mode: mode}
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp executable?(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o111) != 0
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()
end
