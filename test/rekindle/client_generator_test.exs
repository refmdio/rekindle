defmodule Rekindle.ClientGeneratorTest do
  use ExUnit.Case, async: false

  alias Rekindle.ClientGenerator

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
    assert marker["schema"] == 1
    assert marker["application_id"] == "sample_app"
    assert marker["package"] == "sample_app_ui"
    refute Enum.any?(marker["owned_files"], &(&1["path"] == "src/app.rs"))
    assert Enum.any?(marker["owned_files"], &(&1["path"] == ".rekindle-client.json"))
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

  defp copy_client_fixture!(destination) do
    source = Path.expand("crates/rekindle-client")
    File.mkdir_p!(destination)
    File.cp!(Path.join(source, "Cargo.toml"), Path.join(destination, "Cargo.toml"))
    File.cp!(Path.join(source, "Cargo.lock"), Path.join(destination, "Cargo.lock"))
    File.cp_r!(Path.join(source, "src"), Path.join(destination, "src"))
  end
end
