defmodule Rekindle.ClientGeneratorTest do
  use ExUnit.Case, async: false

  alias Rekindle.{ClientGenerator, Failure}

  test "renders a byte-stable shared client with target-specific entry glue" do
    options = options(generate_lock: false)
    first = ClientGenerator.render(options)
    second = ClientGenerator.render(options)

    assert first == second
    assert Map.fetch!(first, "Cargo.lock") == ""
    assert Map.has_key?(first, "src/app.rs")
    assert Map.has_key?(first, "src/bin/web.rs")
    assert Map.has_key?(first, "src/bin/desktop.rs")
    assert first["src/lib.rs"] =~ "rekindle_client::ClientOptions"
    assert first["src/bin/web.rs"] =~ "rekindle_client::web::run"
    assert first["src/bin/desktop.rs"] =~ "rekindle_client::desktop::run"
    assert first["Cargo.toml"] =~ ~s(web = ["rekindle-client/web"])
    assert first["Cargo.toml"] =~ ~s(desktop = ["rekindle-client/desktop"])
    assert first["src/app.rs"] =~ "cx.open_window"
    assert first["src/app.rs"] =~ "Rekindle GPUI"
    refute Map.has_key?(first, "assets")

    marker = Jason.decode!(first[".rekindle-client.json"])

    assert Map.keys(marker) |> Enum.sort() ==
             [
               "application_id",
               "desktop_binary",
               "gpui_revision",
               "owned_files",
               "package",
               "rekindle_client_version",
               "schema",
               "template_version",
               "web_binary"
             ]

    assert marker["schema"] == 1
    assert marker["template_version"] == "2"
    assert marker["application_id"] == "sample_app"
    assert marker["package"] == "sample_app_ui"
    refute Enum.any?(marker["owned_files"], &(&1["path"] == "src/app.rs"))
    assert Enum.any?(marker["owned_files"], &(&1["path"] == ".rekindle-client.json"))
  end

  test "recognizes only the exact supported prior marker identity" do
    options = options(generate_lock: false)
    assert {:ok, prior} = ClientGenerator.render_prior("1", options)

    assert {:ok, recognized} =
             ClientGenerator.recognize_prior(prior[".rekindle-client.json"], options)

    assert recognized.files == prior

    assert Map.keys(recognized.recorded_digests) |> Enum.sort() ==
             ~w[.cargo/config.toml .rekindle-client.json Cargo.toml rust-toolchain.toml src/bin/desktop.rs src/bin/web.rs src/lib.rs]

    assert :error = ClientGenerator.render_prior("0", options)

    marker = Jason.decode!(prior[".rekindle-client.json"])

    for invalid <- [
          Map.delete(marker, "package"),
          Map.put(marker, "extra", true),
          Map.put(marker, "application_id", "foreign"),
          Map.put(marker, "template_version", "0"),
          update_in(marker["owned_files"], &tl/1),
          update_in(marker["owned_files"], fn entries ->
            entries ++ [%{"path" => "foreign", "template_sha256" => String.duplicate("a", 64)}]
          end)
        ] do
      contents = Rekindle.CanonicalValue.encode!(invalid) <> "\n"
      assert :error = ClientGenerator.recognize_prior(contents, options)
    end
  end

  test "keeps the supported version 1 ownership bytes immutable" do
    {:ok, prior} =
      ClientGenerator.render_prior("1",
        application_id: "sample_app",
        package: "sample_app_ui",
        web_binary: "sample_app-web",
        desktop_binary: "sample_app",
        targets: [:web, :desktop]
      )

    marker = Jason.decode!(prior[".rekindle-client.json"])

    assert sha256(prior["Cargo.toml"]) ==
             "7b0974fbe36e1a0b7ccddd90c7747ef0c03ee83c7e7c38e22a1077afe7309fc0"

    assert Enum.find(marker["owned_files"], &(&1["path"] == "Cargo.toml")) == %{
             "path" => "Cargo.toml",
             "template_sha256" =>
               "7b0974fbe36e1a0b7ccddd90c7747ef0c03ee83c7e7c38e22a1077afe7309fc0"
           }
  end

  test "writes a resolvable Cargo project and both intended bins type-check" do
    root = Path.join(System.tmp_dir!(), "rekindle-client-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    fixture_client = Path.join(root, "fixture/rekindle-client")
    copy_client_fixture!(fixture_client)

    written =
      ClientGenerator.write!(
        Path.join(root, "client"),
        options(rekindle_client: {:path, fixture_client})
      )

    root = Path.join(root, "client")
    assert Path.join(root, "Cargo.lock") in written
    assert File.exists?(Path.join(root, "Cargo.lock"))
    desktop_target = Path.expand("_build/test/generated-client-cargo/desktop")
    web_target = Path.expand("_build/test/generated-client-cargo/web")

    assert {_, 0} =
             System.cmd(
               "rustup",
               [
                 "run",
                 "1.95.0",
                 "cargo",
                 "metadata",
                 "--locked",
                 "--format-version",
                 "1",
                 "--no-deps"
               ],
               cd: root,
               stderr_to_stdout: true
             )

    assert {_, 0} =
             System.cmd(
               "rustup",
               [
                 "run",
                 "1.95.0",
                 "cargo",
                 "check",
                 "--locked",
                 "--no-default-features",
                 "--features",
                 "desktop",
                 "--bin",
                 "sample_app"
               ],
               cd: root,
               env: [
                 {"RUSTC", rustc!("1.95.0")},
                 {"CARGO_TARGET_DIR", desktop_target}
               ],
               stderr_to_stdout: true
             )

    assert {_, 0} =
             System.cmd(
               "rustup",
               [
                 "run",
                 "nightly-2026-04-01",
                 "cargo",
                 "check",
                 "--locked",
                 "--target",
                 "wasm32-unknown-unknown",
                 "--no-default-features",
                 "--features",
                 "web",
                 "--bin",
                 "sample_app-web"
               ],
               cd: root,
               env: [
                 {"RUSTC", rustc!("nightly-2026-04-01")},
                 {"CARGO_TARGET_DIR", web_target}
               ],
               stderr_to_stdout: true
             )

    {native_web_output, native_web_status} =
      System.cmd(
        "rustup",
        [
          "run",
          "1.95.0",
          "cargo",
          "check",
          "--locked",
          "--no-default-features",
          "--features",
          "web",
          "--bin",
          "sample_app-web"
        ],
        cd: root,
        env: [
          {"RUSTC", rustc!("1.95.0")},
          {"CARGO_TARGET_DIR", desktop_target}
        ],
        stderr_to_stdout: true
      )

    assert native_web_status != 0
    assert native_web_output =~ "feature `web` is supported only for target_arch = wasm32"
    assert native_web_output =~ "features `web` and `desktop` are mutually exclusive"

    {wasm_desktop_output, wasm_desktop_status} =
      System.cmd(
        "rustup",
        [
          "run",
          "nightly-2026-04-01",
          "cargo",
          "check",
          "--locked",
          "--target",
          "wasm32-unknown-unknown",
          "--no-default-features",
          "--features",
          "desktop",
          "--bin",
          "sample_app"
        ],
        cd: root,
        env: [
          {"RUSTC", rustc!("nightly-2026-04-01")},
          {"CARGO_TARGET_DIR", web_target}
        ],
        stderr_to_stdout: true
      )

    assert wasm_desktop_status != 0
    assert wasm_desktop_output =~ "feature `desktop` is supported only for non-Wasm targets"
    assert wasm_desktop_output =~ "features `web` and `desktop` are mutually exclusive"

    File.write!(
      Path.join(root, "src/bin/desktop.rs"),
      """
      fn build() {}

      fn main() {
          rekindle_client::desktop::run(build, sample_app_ui::client_options()).unwrap();
      }
      """
    )

    {callback_output, callback_status} =
      System.cmd(
        "rustup",
        [
          "run",
          "1.95.0",
          "cargo",
          "check",
          "--locked",
          "--no-default-features",
          "--features",
          "desktop",
          "--bin",
          "sample_app"
        ],
        cd: root,
        env: [
          {"RUSTC", rustc!("1.95.0")},
          {"CARGO_TARGET_DIR", desktop_target}
        ],
        stderr_to_stdout: true
      )

    assert callback_status != 0
    assert callback_output =~ "mismatched types"
    assert callback_output =~ "expected fn pointer"
    assert callback_output =~ "found fn item"
  end

  test "supports an overridden client root without touching Phoenix assets" do
    base = Path.join(System.tmp_dir!(), "rekindle-roots-#{System.unique_integer([:positive])}")
    client = Path.join(base, "ui/client")
    assets = Path.join(base, "assets")
    File.mkdir_p!(assets)
    File.write!(Path.join(assets, "app.js"), "host-owned")
    on_exit(fn -> File.rm_rf!(base) end)

    ClientGenerator.write!(client, options(generate_lock: false))

    assert File.read!(Path.join(assets, "app.js")) == "host-owned"
    assert File.exists?(Path.join(client, "Cargo.toml"))
  end

  test "rejects symlink roots, symlink ancestors, and publication substitution" do
    base =
      Path.join(System.tmp_dir!(), "rekindle-client-root-#{System.unique_integer([:positive])}")

    outside = Path.join(base, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "sentinel"), "outside-owned")
    on_exit(fn -> File.rm_rf!(base) end)
    baseline = directory_snapshot(outside)

    final_link = Path.join(base, "client")
    File.ln_s!(outside, final_link)

    assert_raise ArgumentError, fn ->
      ClientGenerator.write!(final_link, options(generate_lock: false))
    end

    assert directory_snapshot(outside) == baseline
    File.rm!(final_link)

    ancestor_link = Path.join(base, "clients")
    File.ln_s!(outside, ancestor_link)

    assert_raise ArgumentError, fn ->
      ClientGenerator.write!(Path.join(ancestor_link, "gpui"), options(generate_lock: false))
    end

    assert directory_snapshot(outside) == baseline
    File.rm!(ancestor_link)

    substituted = Path.join(base, "substituted")

    assert_raise ArgumentError, fn ->
      ClientGenerator.write!(
        substituted,
        options(
          generate_lock: false,
          before_publish: fn root, _staging -> File.ln_s!(outside, root) end
        )
      )
    end

    assert directory_snapshot(outside) == baseline

    reconciled = Path.join(base, "reconciled")
    displaced = Path.join(base, "reconciled-displaced")
    ClientGenerator.write!(reconciled, options(generate_lock: false))

    assert_raise ArgumentError, fn ->
      ClientGenerator.reconcile!(
        reconciled,
        options(generate_lock: false),
        generate_lock: false,
        before_publish: fn root, _staging ->
          File.rename!(root, displaced)
          File.ln_s!(outside, root)
        end
      )
    end

    assert directory_snapshot(outside) == baseline
  end

  test "reconciles admitted clients transactionally while preserving application files" do
    base =
      Path.join(
        System.tmp_dir!(),
        "rekindle-client-reconcile-#{System.unique_integer([:positive])}"
      )

    client = Path.join(base, "client")
    on_exit(fn -> File.rm_rf!(base) end)
    ClientGenerator.write!(client, options(generate_lock: false))
    File.write!(Path.join(client, "Cargo.lock"), "application-lock\n")
    File.write!(Path.join(client, "src/app.rs"), "application-ui\n")
    File.write!(Path.join(client, "public/theme.css"), "application-theme\n")

    ClientGenerator.reconcile!(client, options(generate_lock: false), generate_lock: false)

    assert File.read!(Path.join(client, "Cargo.lock")) == "application-lock\n"
    assert File.read!(Path.join(client, "src/app.rs")) == "application-ui\n"
    assert File.read!(Path.join(client, "public/theme.css")) == "application-theme\n"

    assert File.read!(Path.join(client, "Cargo.toml")) ==
             ClientGenerator.render(options(generate_lock: false))["Cargo.toml"]
  end

  test "manual generation returns a bounded typed failure without command output" do
    base =
      Path.join(
        System.tmp_dir!(),
        "rekindle-client-failure-#{System.unique_integer([:positive])}"
      )

    rustup = Path.join(base, "rustup")
    client = Path.join(base, "client")
    secret = "manual-lock-secret"
    File.mkdir_p!(base)

    File.write!(
      rustup,
      "#!/bin/sh\nprintf '%s\\n' '#{secret} /private/build/path' >&2\nexit 41\n"
    )

    File.chmod!(rustup, 0o700)
    on_exit(fn -> File.rm_rf!(base) end)

    with_env("REKINDLE_RUSTUP", rustup, fn ->
      assert {:error, %Failure{} = failure} = ClientGenerator.write(client, options([]))
      assert failure.stage == :execution
      assert failure.code == :cargo_failed
      assert failure.message == "Cargo.lock generation failed with status 41"
      refute failure.message =~ secret
      refute failure.message =~ "/private/build/path"
      assert byte_size(failure.message) < 512
      refute File.exists?(client)
    end)
  end

  defp options(extra) do
    [
      application_id: "sample_app",
      package: "sample_app_ui",
      web_binary: "sample_app-web",
      desktop_binary: "sample_app",
      targets: [:web, :desktop],
      rekindle_client: {:path, Path.expand("crates/rekindle-client")}
    ]
    |> Keyword.merge(extra)
  end

  defp rustc!(toolchain) do
    {path, 0} = System.cmd("rustup", ["which", "--toolchain", toolchain, "rustc"])
    String.trim(path)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp directory_snapshot(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.sort()
    |> Map.new(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
  end

  defp copy_client_fixture!(destination) do
    source = Path.expand("crates/rekindle-client")
    File.mkdir_p!(destination)
    File.cp!(Path.join(source, "Cargo.toml"), Path.join(destination, "Cargo.toml"))
    File.cp!(Path.join(source, "Cargo.lock"), Path.join(destination, "Cargo.lock"))
    File.cp_r!(Path.join(source, "src"), Path.join(destination, "src"))
  end

  defp with_env(name, value, function) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      function.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end
end
