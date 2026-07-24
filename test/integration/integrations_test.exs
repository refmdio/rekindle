defmodule Rekindle.IntegrationsTest do
  use ExUnit.Case, async: false

  alias Rekindle.Integration
  alias Rekindle.Test.IntegrationBrowser

  @moduletag timeout: 600_000

  test "renders application-owned sources for every built-in integration" do
    assert Enum.sort(Integration.names()) == [:egui, :gpui, :slint]

    for name <- Integration.names() do
      framework = Integration.dependency(name)
      both = Integration.render(name, [:web, :desktop], package_name: "sample-client")
      web = Integration.render(name, [:web])
      desktop = Integration.render(name, [:desktop])

      expected_files =
        case name do
          :gpui ->
            ["Cargo.lock", "Cargo.toml", "rust-toolchain.toml", "src/lib.rs"]

          :egui ->
            ["Cargo.lock", "Cargo.toml", "rust-toolchain.toml", "src/app.rs", "src/lib.rs"]

          :slint ->
            [
              "Cargo.lock",
              "Cargo.toml",
              "build.rs",
              "rust-toolchain.toml",
              "src/lib.rs",
              "ui/app-window.slint"
            ]
        end

      assert Map.keys(both) |> Enum.sort() ==
               Enum.sort(expected_files ++ ["src/bin/desktop.rs", "src/bin/web.rs"])

      assert Map.has_key?(web, "src/bin/web.rs")
      refute Map.has_key?(web, "src/bin/desktop.rs")
      assert Map.has_key?(desktop, "src/bin/desktop.rs")
      refute Map.has_key?(desktop, "src/bin/web.rs")

      assert both["Cargo.toml"] =~ ~s(name = "sample-client")
      assert both["Cargo.lock"] =~ ~s(name = "sample-client")
      assert both["Cargo.toml"] =~ framework

      assert_framework_entrypoints(name, both)

      assert both["Cargo.toml"] =~
               ~s(wasm-bindgen = "=#{Rekindle.Toolchain.wasm_bindgen_version()}")

      refute both["Cargo.toml"] =~ ~r/^rekindle(?:_|-|\s*=)/m
      refute both["src/bin/web.rs"] =~ "rekindleReady"
      refute both["src/bin/web.rs"] =~ "rekindleStatus"
      refute Enum.any?(both, fn {_path, source} -> source =~ "Rekindle" end)
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

  test "requires rendered surface pixels without browser failures" do
    blank_surface = %{
      "error" => nil,
      "surface" => %{"present" => true, "visible" => true, "varied" => false}
    }

    rendered_surface = %{
      "error" => nil,
      "surface" => %{"present" => true, "visible" => true, "varied" => true}
    }

    assert {:pending, ^blank_surface} =
             IntegrationBrowser.classify_observation(blank_surface, [])

    assert {:ok, :ready} = IntegrationBrowser.classify_observation(rendered_surface, [])

    assert {:error, "startup error: frame failed"} =
             IntegrationBrowser.classify_observation(
               put_in(rendered_surface["error"], "frame failed"),
               []
             )

    assert {:error, "severe browser log: uncaught exception"} =
             IntegrationBrowser.classify_observation(rendered_surface, [
               %{"level" => "SEVERE", "message" => "uncaught exception"}
             ])
  end

  test "generated clients compile for every target selection" do
    for name <- Integration.names() do
      for targets <- [[:web], [:desktop], [:web, :desktop]] do
        root = tmp_dir("#{name}-#{Enum.join(targets, "-")}")
        write(root, Integration.render(name, targets))
        commit_generated_client!(root)
        dependency_names = cargo_dependency_names!(root)

        assert Integration.dependency(name) in dependency_names
        refute Enum.any?(dependency_names, &String.starts_with?(&1, "rekindle"))
        cargo_fmt!(root)

        if :web in targets,
          do: cargo_check!(root, "web", "wasm32-unknown-unknown")

        if :desktop in targets,
          do: cargo_check!(root, "desktop", desktop_target!())

        assert git_status!(root) == ""
      end
    end
  end

  test "packages Web and desktop generations for every built-in integration" do
    previous = Application.get_env(:rekindle_integration_matrix_test, Rekindle)

    on_exit(fn ->
      if previous do
        Application.put_env(:rekindle_integration_matrix_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_integration_matrix_test, Rekindle)
      end
    end)

    for name <- Integration.names() do
      root = tmp_dir("#{name}-package")
      client = Path.join(root, "client")
      package = "matrix_#{name}"
      write(client, Integration.render(name, [:web, :desktop], package_name: package))

      Application.put_env(:rekindle_integration_matrix_test, Rekindle,
        integration: name,
        targets: [
          web: [package: package, binary: "web", features: ["web"]],
          desktop: [package: package, binary: "desktop", features: ["desktop"]]
        ]
      )

      cargo = rustup_tool!(client, "cargo")
      {rustc, 0} = System.cmd("rustup", ["which", "rustc"], cd: client)

      environment =
        System.get_env()
        |> Map.put(
          "CARGO_TARGET_DIR",
          Path.join(System.tmp_dir!(), "rekindle-integration-package-target")
        )
        |> Map.put("CARGO_TERM_COLOR", "never")
        |> Map.put("RUSTC", String.trim(rustc))

      options = [
        otp_app: :rekindle_integration_matrix_test,
        project_root: root,
        cargo: cargo,
        rustc: String.trim(rustc),
        env: environment
      ]

      assert {:ok, web} = Rekindle.build(:web, options)
      assert web.metadata.package == package
      assert web.metadata.rust_target == "wasm32-unknown-unknown"
      assert File.regular?(web.artifact)
      assert File.regular?(web.metadata.manifest)
      IntegrationBrowser.assert_starts!(web.artifact, name, root)

      assert {:ok, desktop} = Rekindle.build(:desktop, options)
      assert desktop.metadata.package == package
      assert desktop.metadata.rust_target == desktop_target!()
      assert File.regular?(desktop.artifact)
      assert File.regular?(desktop.metadata.manifest)
      assert_desktop_starts!(desktop.artifact, name)
    end
  end

  defp write(root, files) do
    Enum.each(files, fn {relative, contents} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)
  end

  defp assert_framework_entrypoints(:gpui, files) do
    assert files["Cargo.toml"] =~ ~s(features = ["wayland", "x11"])
    assert files["src/bin/web.rs"] =~ "use std::cell::OnceCell;"
    assert files["src/bin/web.rs"] =~ "gpui_platform::web_init();"
    assert files["src/bin/web.rs"] =~ "gpui_platform::application().run_embedded"
    refute files["src/bin/web.rs"] =~ "single_threaded_web"
    assert files["src/bin/desktop.rs"] =~ "gpui_platform::application().run"
    assert files["src/lib.rs"] =~ ~S|format!("Hello, {}!", &self.text)|
    assert files["src/lib.rs"] =~ "gpui::red()"
  end

  defp assert_framework_entrypoints(:egui, files) do
    assert files["Cargo.toml"] =~
             ~s(features = ["default_fonts", "glow", "persistence", "wayland", "x11"])

    assert files["src/bin/web.rs"] =~ "use wasm_bindgen::JsCast;"
    assert files["src/bin/web.rs"] =~ "eframe::WebRunner::new()"
    assert files["src/bin/desktop.rs"] =~ "eframe::run_native("
    assert files["src/lib.rs"] =~ "pub use app::TemplateApp;"
    assert files["src/app.rs"] =~ ~S|ui.heading("eframe template");|
    assert files["src/app.rs"] =~ ~S|ui.text_edit_singleline(&mut self.label);|
    assert files["src/app.rs"] =~ "egui::Slider::new"
  end

  defp assert_framework_entrypoints(:slint, files) do
    assert files["Cargo.toml"] =~
             ~s(features = ["compat-1-2", "renderer-femtovg", "backend-winit", "std"])

    assert files["Cargo.toml"] =~ ~s(slint-build = "1.16")
    assert files["build.rs"] =~ ~S|slint_build::compile("ui/app-window.slint")|
    assert files["src/lib.rs"] =~ "slint::include_modules!();"
    assert files["src/lib.rs"] =~ "AppWindow::new()"
    assert files["src/bin/web.rs"] =~ "::run()"
    assert files["src/bin/desktop.rs"] =~ "::run()"
    assert files["ui/app-window.slint"] =~ "Counter: \\{root.counter}"
    assert files["ui/app-window.slint"] =~ ~s(text: "Increase value";)
  end

  defp cargo_check!(root, target, triple) do
    cargo = rustup_tool!(root, "cargo")
    {rustc, 0} = System.cmd("rustup", ["which", "rustc"], cd: root)

    {output, status} =
      System.cmd(
        String.trim(cargo),
        ["check", "--locked", "--target", triple, "--bin", target, "--features", target],
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

  defp commit_generated_client!(root) do
    git!(root, ["init", "--quiet"])
    git!(root, ["config", "user.email", "rekindle-test@example.invalid"])
    git!(root, ["config", "user.name", "Rekindle Test"])
    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "generated client"])
  end

  defp git_status!(root) do
    {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: root)
    output
  end

  defp git!(root, arguments) do
    {output, status} = System.cmd("git", arguments, cd: root, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(arguments, " ")} failed:\n#{output}"
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

  defp desktop_target! do
    target = Rekindle.Toolchain.desktop_target()
    assert {:ok, ^target} = Rekindle.Toolchain.target(:desktop)
    target
  end

  defp assert_desktop_starts!(artifact, integration) do
    case Rekindle.Toolchain.Process.run(artifact, [],
           cd: Path.dirname(artifact),
           timeout: 1_000,
           output_limit: 64_000
         ) do
      {:error, :timeout} ->
        :ok

      {:ok, result} ->
        flunk(
          "#{integration} desktop exited during startup with status #{result.status}:\n#{result.output}"
        )

      {:error, reason} ->
        flunk("#{integration} desktop could not start: #{inspect(reason)}")
    end
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
