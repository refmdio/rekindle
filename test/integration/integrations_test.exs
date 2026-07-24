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

      if name == :gpui do
        assert both["Cargo.toml"] =~ ~s(features = ["wayland", "x11"])
      end

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

  test "generated clients compile for every target selection" do
    for name <- Integration.names() do
      for targets <- [[:web], [:desktop], [:web, :desktop]] do
        root = tmp_dir("#{name}-#{Enum.join(targets, "-")}")
        write(root, Integration.render(name, targets))
        dependency_names = cargo_dependency_names!(root)

        assert Integration.dependency(name) in dependency_names
        refute Enum.any?(dependency_names, &String.starts_with?(&1, "rekindle"))
        cargo_fmt!(root)

        if :web in targets,
          do: cargo_check!(root, "web", "wasm32-unknown-unknown")

        if :desktop in targets,
          do: cargo_check!(root, "desktop", host_target!())
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
      assert_web_starts!(web.artifact, name, root)

      assert {:ok, desktop} = Rekindle.build(:desktop, options)
      assert desktop.metadata.package == package
      assert desktop.metadata.rust_target == host_target!()
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

  defp host_target! do
    {:ok, target} = Rekindle.Toolchain.host_target()
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

  defp assert_web_starts!(artifact, integration, root) do
    browser = System.find_executable("chromium") || flunk("Chromium is required for Web startup")
    host_root = Path.join(root, "browser")
    profile = Path.join(root, "chromium-profile")
    File.cp_r!(Path.dirname(artifact), host_root)

    {:ok, %{host: host}} = Integration.fetch(integration)
    File.write!(Path.join(host_root, "index.html"), browser_host(host))

    {:ok, _applications} = Application.ensure_all_started(:inets)

    {:ok, server} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"rekindle",
        server_root: String.to_charlist(host_root),
        document_root: String.to_charlist(host_root),
        modules: [:mod_alias, :mod_dir, :mod_get, :mod_head],
        directory_index: [~c"index.html"],
        mime_types: [
          {~c"html", ~c"text/html"},
          {~c"js", ~c"text/javascript"},
          {~c"wasm", ~c"application/wasm"}
        ]
      )

    port = :httpd.info(server) |> Keyword.fetch!(:port)

    try do
      arguments = [
        "--headless=new",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-dev-shm-usage",
        "--user-data-dir=#{profile}",
        "--virtual-time-budget=5000",
        "--dump-dom",
        "http://127.0.0.1:#{port}/"
      ]

      case Rekindle.Toolchain.Process.run(browser, arguments,
             cd: host_root,
             timeout: 30_000,
             output_limit: 1_000_000
           ) do
        {:ok, %{status: 0, output: output}} ->
          assert output =~ ~s(data-rekindle-status="ready"),
                 "#{integration} Web startup failed:\n#{output}"

        {:ok, result} ->
          flunk("#{integration} Chromium exited with status #{result.status}:\n#{result.output}")

        {:error, reason} ->
          flunk("#{integration} Chromium startup failed: #{inspect(reason)}")
      end
    after
      :inets.stop(:httpd, server)
    end
  end

  defp browser_host(host) do
    """
    <!doctype html>
    <html data-rekindle-status="pending">
      <head><meta charset="utf-8"><title>Rekindle startup</title></head>
      <body>
        #{host}
        <script type="module">
          const root = document.documentElement;
          const fail = (error) => {
            const message = String(error?.reason ?? error?.error ?? error);
            root.dataset.rekindleStatus = "error";
            root.dataset.rekindleError = message;
          };
          window.addEventListener("error", fail);
          window.addEventListener("unhandledrejection", fail);

          try {
            if (!window.isSecureContext) throw new Error("insecure context");
            const module = await import("./app.js");
            await module.default();
          } catch (error) {
            fail(error);
          }
        </script>
      </body>
    </html>
    """
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
