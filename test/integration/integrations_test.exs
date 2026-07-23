defmodule Rekindle.IntegrationsTest do
  use ExUnit.Case, async: false

  alias Rekindle.Integration

  @moduletag timeout: 600_000

  test "renders application-owned sources for every built-in integration" do
    assert Enum.sort(Integration.names()) == [:egui, :gpui, :slint]

    for name <- Integration.names() do
      framework = Integration.dependency(name)
      both = Integration.render(name, [:web, :desktop], package_name: "sample-client")
      web = Integration.render(name, [:web])
      desktop = Integration.render(name, [:desktop])

      assert Map.keys(both) |> Enum.sort() ==
               [
                 "Cargo.toml",
                 "rust-toolchain.toml",
                 "src/bin/desktop.rs",
                 "src/bin/web.rs",
                 "src/lib.rs"
               ]

      assert Map.has_key?(web, "src/bin/web.rs")
      refute Map.has_key?(web, "src/bin/desktop.rs")
      assert Map.has_key?(desktop, "src/bin/desktop.rs")
      refute Map.has_key?(desktop, "src/bin/web.rs")

      assert both["Cargo.toml"] =~ ~s(name = "sample-client")
      assert both["Cargo.toml"] =~ framework

      assert both["Cargo.toml"] =~
               ~s(wasm-bindgen = "=#{Rekindle.Toolchain.wasm_bindgen_version()}")

      refute both["Cargo.toml"] =~ ~r/^rekindle(?:_|-|\s*=)/m
      assert both["src/lib.rs"] != ""
      assert both["src/bin/web.rs"] =~ "sample_client"
      assert both["src/bin/desktop.rs"] =~ "sample_client"
    end
  end

  test "keeps host and graphics requirements with each integration" do
    assert {:ok, %{graphics: %{web: :webgpu}, host: ""}} = Integration.fetch(:gpui)

    assert {:ok, %{graphics: %{web: :webgl2}, host: egui_host}} =
             Integration.fetch(:egui)

    assert egui_host =~ ~s(id="rekindle-canvas")

    assert {:ok, %{graphics: %{web: :webgl2}, host: slint_host}} =
             Integration.fetch(:slint)

    assert slint_host =~ ~s(id="canvas")
  end

  test "generated clients compile for Web and desktop" do
    for name <- Integration.names() do
      root = tmp_dir(name)
      write(root, Integration.render(name, [:web, :desktop]))
      dependency_names = cargo_dependency_names!(root)

      assert Integration.dependency(name) in dependency_names
      refute Enum.any?(dependency_names, &String.starts_with?(&1, "rekindle"))
      cargo_fmt!(root)
      cargo_check!(root, "web", "wasm32-unknown-unknown")
      cargo_check!(root, "desktop", "x86_64-unknown-linux-gnu")
    end
  end

  defp write(root, files) do
    Enum.each(files, fn {relative, contents} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)
  end

  defp cargo_check!(root, target, triple) do
    cargo = rustup_tool!(root, "cargo")
    {rustc, 0} = System.cmd("rustup", ["which", "rustc"], cd: root)

    {output, status} =
      System.cmd(
        String.trim(cargo),
        ["check", "--target", triple, "--bin", target, "--features", target],
        cd: root,
        env: [
          {"CARGO_TARGET_DIR", Path.join(System.tmp_dir!(), "rekindle-integration-target")},
          {"CARGO_TERM_COLOR", "never"},
          {"RUSTC", String.trim(rustc)}
        ],
        stderr_to_stdout: true
      )

    assert status == 0,
           "cargo check failed for #{Path.basename(root)} #{target}:\n#{output}"
  end

  defp cargo_dependency_names!(root) do
    {output, 0} =
      System.cmd(rustup_tool!(root, "cargo"), ["metadata", "--format-version", "1", "--no-deps"],
        cd: root,
        stderr_to_stdout: true
      )

    output
    |> Jason.decode!()
    |> Map.fetch!("packages")
    |> List.first()
    |> Map.fetch!("dependencies")
    |> Enum.map(&Map.fetch!(&1, "name"))
  end

  defp cargo_fmt!(root) do
    {output, status} =
      System.cmd(rustup_tool!(root, "cargo"), ["fmt", "--all", "--", "--check"],
        cd: root,
        stderr_to_stdout: true
      )

    assert status == 0, "generated Rust is not formatted:\n#{output}"
  end

  defp rustup_tool!(root, tool) do
    {path, 0} = System.cmd("rustup", ["which", tool], cd: root)
    String.trim(path)
  end

  defp tmp_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
