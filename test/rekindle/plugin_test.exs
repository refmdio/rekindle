defmodule Rekindle.PluginTest do
  use ExUnit.Case, async: false

  alias Rekindle.Install.Client
  alias Rekindle.Plugin

  @moduletag timeout: 600_000
  @plugins [
    gpui: Rekindle.Plugin.GPUI,
    egui: Rekindle.Plugin.Egui,
    slint: Rekindle.Plugin.Slint
  ]

  defmodule CustomPlugin do
    @behaviour Rekindle.Plugin

    @impl true
    def name, do: "custom"

    @impl true
    def spec(options) do
      base = Rekindle.Plugin.GPUI.spec([])
      %{base | name: name(), web: %{base.web | host: Keyword.get(options, :host, "")}}
    end
  end

  test "loads an external plugin module with options" do
    plugin = {CustomPlugin, host: ~s(<canvas id="custom"></canvas>)}

    assert {:ok, {CustomPlugin, [host: _host], spec}} = Plugin.load(plugin)
    assert spec.name == "custom"
    assert spec.web.host == ~s(<canvas id="custom"></canvas>)
    assert Client.render(plugin, [:desktop])["src/bin/desktop.rs"] =~ "client::open"
  end

  test "renders application-owned sources for every built-in plugin" do
    assert Enum.sort(Plugin.builtin_names()) == [:egui, :gpui, :slint]

    for {name, module} <- @plugins do
      spec = Plugin.spec(module)
      both = Client.render(module, [:web, :desktop])
      web = Client.render(module, [:web])
      desktop = Client.render(module, [:desktop])

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

      assert both["Cargo.toml"] =~ ~s(name = "client")
      assert both["Cargo.lock"] =~ ~s(name = "client")
      assert both["Cargo.toml"] =~ spec.dependency

      assert_framework_entrypoints(name, both)

      assert both["Cargo.toml"] =~
               ~s(wasm-bindgen = "=#{Rekindle.Toolchain.wasm_bindgen_version()}")

      for rendered <- [both, web, desktop] do
        refute Enum.any?(rendered, fn {_path, source} -> source =~ ~r/rekindle/i end)
      end

      assert both["src/lib.rs"] != ""
      assert both["src/bin/web.rs"] =~ "client"
      assert both["src/bin/desktop.rs"] =~ "client"
    end
  end

  test "keeps host and graphics requirements with each plugin" do
    assert %{web: %{graphics: :webgpu, host: "", style: gpui_style}} =
             Plugin.spec(Rekindle.Plugin.GPUI)

    assert gpui_style =~ "body > canvas"
    assert gpui_style =~ "touch-action: none"

    assert %{web: %{graphics: :webgl2, host: egui_host, style: egui_style}} =
             Plugin.spec(Rekindle.Plugin.Egui)

    assert egui_host == ~s(<canvas id="the_canvas_id"></canvas>)
    assert egui_style =~ "#the_canvas_id"
    assert egui_style =~ "width: 100%"

    assert %{web: %{graphics: :webgl2, host: slint_host, style: slint_style}} =
             Plugin.spec(Rekindle.Plugin.Slint)

    assert slint_host =~ ~s(id="canvas")
    assert slint_style =~ "#canvas"
    assert slint_style =~ "height: 100%"

    for {_name, module} <- @plugins do
      %{web: %{host: host, style: style}} = Plugin.spec(module)
      assert Rekindle.Phoenix.web_host(module) == host
      assert Rekindle.Phoenix.web_style(module) == style
      refute host =~ ~r/rekindle/i
      refute style =~ ~r/rekindle/i
    end

    assert Rekindle.Phoenix.web_host(Rekindle.Plugin.GPUI) == ""

    assert Rekindle.Phoenix.web_host(Rekindle.Plugin.Egui) ==
             ~s(<canvas id="the_canvas_id"></canvas>)

    assert Rekindle.Phoenix.web_host(Rekindle.Plugin.Slint) == ~s(<canvas id="canvas"></canvas>)
  end

  @tag :plugin_matrix
  test "generated clients compile for every target selection" do
    for {name, module} <- selected_plugins() do
      for targets <- [[:web], [:desktop], [:web, :desktop]] do
        root = tmp_dir("#{name}-#{Enum.join(targets, "-")}")
        write(root, Client.render(module, targets))
        commit_generated_client!(root)
        dependency_names = cargo_dependency_names!(root)

        assert Plugin.spec(module).dependency in dependency_names
        refute Enum.any?(dependency_names, &String.starts_with?(&1, "rekindle"))

        if name == :slint do
          assert_slint_versions!(root)
        end

        cargo_fmt!(root)

        if :web in targets,
          do: cargo_check!(root, "web", "wasm32-unknown-unknown")

        if :desktop in targets,
          do: cargo_check!(root, "desktop", desktop_target!())

        assert git_status!(root) == ""
      end
    end
  end

  @tag timeout: 1_800_000
  @tag :plugin_matrix
  test "packages Web and desktop generations for every built-in plugin" do
    previous = Application.get_env(:rekindle_plugin_matrix_test, Rekindle)

    on_exit(fn ->
      if previous do
        Application.put_env(:rekindle_plugin_matrix_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_plugin_matrix_test, Rekindle)
      end
    end)

    for {name, module} <- selected_plugins() do
      root = tmp_dir("#{name}-package")
      client = Path.join(root, "client")
      package = "client"
      write(client, Client.render(module, [:web, :desktop]))

      Application.put_env(:rekindle_plugin_matrix_test, Rekindle,
        plugin: module,
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
          Path.join(System.tmp_dir!(), "rekindle-plugin-package-target")
        )
        |> Map.put("CARGO_TERM_COLOR", "never")
        |> Map.put("RUSTC", String.trim(rustc))

      options = [
        otp_app: :rekindle_plugin_matrix_test,
        project_root: root,
        cargo: cargo,
        rustc: String.trim(rustc),
        env: environment,
        timeout: 600_000
      ]

      assert {:ok, web} = Rekindle.build(:web, Keyword.put(options, :profile, :release))
      assert web.metadata.package == package
      assert web.metadata.rust_target == "wasm32-unknown-unknown"
      assert File.regular?(web.artifact)

      assert {:ok, desktop} = Rekindle.build(:desktop, options)
      assert desktop.metadata.package == package
      assert desktop.metadata.rust_target == desktop_target!()
      assert File.regular?(desktop.artifact)
      assert File.regular?(desktop.metadata.manifest)
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
    assert files["src/lib.rs"] =~ ~S|format!("Hello, {}!", self.text)|
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

    assert files["Cargo.toml"] =~ ~s(slint = "=1.16.1")
    assert files["Cargo.toml"] =~ ~s(i-slint-backend-winit = "=1.16.1")
    assert files["Cargo.toml"] =~ ~s(slint-build = "=1.16.1")
    assert files["Cargo.lock"] =~ ~r/name = "slint"\nversion = "1\.16\.1"/
    assert files["Cargo.lock"] =~ ~r/name = "slint-build"\nversion = "1\.16\.1"/
    assert files["build.rs"] =~ ~S|slint_build::compile("ui/app-window.slint")|
    assert files["src/lib.rs"] =~ "slint::include_modules!();"
    assert files["src/lib.rs"] =~ "AppWindow::new()"
    assert files["src/bin/web.rs"] =~ "OnceCell"
    assert files["src/bin/web.rs"] =~ "::create()"
    assert files["src/bin/web.rs"] =~ ".show()"
    assert files["src/bin/web.rs"] =~ ".with_spawn_event_loop(true)"
    assert files["src/bin/web.rs"] =~ "slint::platform::set_platform"
    assert files["src/bin/web.rs"] =~ "slint::run_event_loop()"
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
          {"CARGO_TARGET_DIR", Path.join(System.tmp_dir!(), "rekindle-plugin-target")},
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

  defp assert_slint_versions!(root) do
    {output, status} =
      System.cmd(rustup_tool!(root, "cargo"), ["metadata", "--format-version", "1", "--locked"],
        cd: root
      )

    assert status == 0, "cargo metadata failed for generated Slint client"

    packages =
      output
      |> Jason.decode!()
      |> Map.fetch!("packages")
      |> Enum.filter(fn package ->
        package["name"] in ["slint", "slint-build", "slint-macros"] or
          String.starts_with?(package["name"], "i-slint-")
      end)

    assert Enum.any?(packages, &(&1["name"] == "slint"))
    assert Enum.any?(packages, &(&1["name"] == "slint-build"))

    assert Enum.all?(packages, &(&1["version"] == "1.16.1")),
           "generated Slint client resolved unexpected versions: #{inspect(packages)}"
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

  defp selected_plugins do
    case System.get_env("REKINDLE_PLUGIN") do
      nil ->
        @plugins

      selected ->
        case Enum.find(@plugins, fn {name, _module} -> Atom.to_string(name) == selected end) do
          nil -> raise "unknown REKINDLE_PLUGIN: #{selected}"
          plugin -> [plugin]
        end
    end
  end

  defp desktop_target! do
    {:ok, target} = Rekindle.Toolchain.host_target()
    assert {:ok, ^target} = Rekindle.Toolchain.target(:desktop)
    target
  end

  defp tmp_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-#{name}-#{System.pid()}-#{random_token()}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp random_token do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
