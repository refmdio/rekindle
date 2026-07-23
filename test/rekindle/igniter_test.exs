defmodule Rekindle.IgniterTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  alias Rekindle.ClientGenerator
  alias Rekindle.Igniter, as: RekindleIgniter

  test "public Mix command inventory excludes installer-owned client lock machinery" do
    Mix.Task.load_all()

    assert Mix.Task.get("rekindle.install") == Mix.Tasks.Rekindle.Install
    assert Mix.Task.get("rekindle.setup") == Mix.Tasks.Rekindle.Setup
    assert Mix.Task.get("rekindle.client.lock") == nil
    refute File.exists?("lib/mix/tasks/rekindle.client.lock.ex")
    refute function_exported?(ClientGenerator, :generate_lock, 1)
  end

  test "production alias preserves its prefix and replaces one terminal digest" do
    assert {:ok, ["cmd npm deploy", "rekindle.phoenix.deploy"]} =
             RekindleIgniter.transform_assets_deploy(["cmd npm deploy", "phx.digest"])

    assert {:ok, ["rekindle.phoenix.deploy"]} =
             RekindleIgniter.transform_assets_deploy(["phx.digest"])
  end

  test "production alias rejects absent, duplicate, nonterminal, and dynamic shapes" do
    invalid = [
      [],
      ["cmd npm deploy"],
      ["phx.digest", "phx.digest"],
      ["phx.digest", "cmd after"],
      ["rekindle.phoenix.deploy", "phx.digest"],
      ["phx.digest", "rekindle.phoenix.deploy"],
      ["rekindle.phoenix.deploy", "rekindle.phoenix.deploy"],
      {:dynamic, :alias}
    ]

    for value <- invalid do
      assert {:error, _message} = RekindleIgniter.transform_assets_deploy(value)
    end

    for value <- [
          ["phx.digest", "rekindle.phoenix.deploy --force"],
          ["cmd rekindle.phoenix.deploy", "phx.digest"]
        ] do
      assert {:error, message} = RekindleIgniter.transform_assets_deploy(value)
      assert message =~ "foreign or malformed"
    end
  end

  test "development build alias recognizes only one exact terminal owned step" do
    assert {:ok, ["cmd host.build", "rekindle.build web"]} =
             RekindleIgniter.transform_assets_build(["cmd host.build"])

    assert {:ok, ["cmd host.build", "rekindle.build web"]} =
             RekindleIgniter.transform_assets_build(["cmd host.build", "rekindle.build web"])

    for value <- [
          ["rekindle.build web", "cmd after"],
          ["rekindle.build web", "rekindle.build web"],
          ["rekindle.build desktop"],
          ["cmd rekindle.build web"],
          {:dynamic, :alias}
        ] do
      assert {:error, _message} = RekindleIgniter.transform_assets_build(value)
    end

    assert {:ok, ["cmd my_rekindle.build", "rekindle.build web"]} =
             RekindleIgniter.transform_assets_build(["cmd my_rekindle.build"])
  end

  test "fresh install is semantically idempotent and preserves unrelated host content" do
    initial = project()

    proposal =
      RekindleIgniter.install(initial,
        client_path: "client",
        targets: [:web, :desktop],
        endpoint: SampleAppWeb.Endpoint
      )

    assert source(proposal, ".gitignore") =~ "/.rekindle/"
    assert source(proposal, ".gitignore") =~ "/client/.rekindle/"
    assert source(proposal, "client/Cargo.lock") == ""
    assert source(proposal, "client/rust-toolchain.toml") =~ ~s(channel = "nightly-2026-04-01")
    assert_client_reconciliation_task(proposal, "client")

    installed = apply_igniter!(proposal)

    assert Rewrite.source!(installed.rewrite, "client/Cargo.toml")
    assert source(installed, "client/src/lib.rs") =~ "rekindle_client::ClientOptions"
    assert source(installed, "config/config.exs") =~ "nightly-2026-04-01"

    assert source(installed, "lib/sample_app_web/components/layouts/root.html.heex") =~
             "Rekindle.Phoenix.Components.gpui_page"

    assert source(installed, "lib/sample_app_web/components/layouts/root.html.heex") =~
             "host-owned"

    endpoint = source(installed, "lib/sample_app_web/endpoint.ex")
    assert endpoint =~ "if code_reloading? do"
    assert endpoint =~ ~s(socket("/_rekindle/socket", Rekindle.Phoenix.Socket)
    assert endpoint =~ "plug(Rekindle.Phoenix.DevPlug, otp_app: :sample_app)"
    assert index(endpoint, "Rekindle.Phoenix.DevPlug") < index(endpoint, "SampleAppWeb.Router")
    assert source(installed, "lib/sample_app_web.ex") =~ ~s("rekindle")

    application = source(installed, "lib/sample_app/application.ex")
    assert application =~ "SampleApp.HostChild"
    assert application =~ "Code.ensure_loaded?(Mix) and Mix.env() != :prod"
    assert Regex.match?(~r/else\s+\[\]/, application)

    assert source(installed, "mix.exs") =~
             ~s(["cmd host.build", "rekindle.build web"])

    assert source(installed, "mix.exs") =~
             ~s(["cmd host.deploy", "rekindle.phoenix.deploy"])

    reinstalled =
      RekindleIgniter.install(installed,
        client_path: "client",
        targets: [:web, :desktop],
        endpoint: SampleAppWeb.Endpoint
      )

    assert reinstalled.issues == []
    assert source(reinstalled, "mix.exs") == source(installed, "mix.exs")
    assert source(reinstalled, "lib/sample_app_web/endpoint.ex") == endpoint
    assert count(source(reinstalled, "lib/sample_app_web.ex"), ~s("rekindle")) == 1

    assert count(
             source(reinstalled, "lib/sample_app_web/components/layouts/root.html.heex"),
             "gpui_page"
           ) == 1

    ignore_lines = String.split(source(reinstalled, ".gitignore"), "\n")
    assert Enum.count(ignore_lines, &(&1 == "/.rekindle/")) == 1
    assert Enum.count(ignore_lines, &(&1 == "/client/.rekindle/")) == 1
  end

  test "discovers the selected endpoint root layout independently of the OTP app name" do
    custom_layout = "lib/portal_ui/shell/layouts/root.html.heex"

    installed =
      project(
        layout_path: nil,
        extra_files: %{
          "lib/portal_ui.ex" => """
          defmodule PortalUI do
            def static_paths, do: ~w(assets images favicon.ico)
          end
          """,
          "lib/portal_ui/endpoint.ex" => """
          defmodule PortalUI.Endpoint do
            use Phoenix.Endpoint, otp_app: :sample_app
            plug PortalUI.Router
          end
          """,
          custom_layout => "<!doctype html>\n<html><body><p>portal-owned</p></body></html>\n"
        }
      )
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web],
        endpoint: PortalUI.Endpoint
      )

    assert installed.issues == []
    assert source(installed, custom_layout) =~ "Rekindle.Phoenix.Components.gpui_page"
    assert source(installed, custom_layout) =~ "portal-owned"
  end

  test "rejects missing and ambiguous root layout sites for the selected endpoint" do
    missing =
      project(layout_path: nil)
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web],
        endpoint: SampleAppWeb.Endpoint
      )

    assert Enum.any?(missing.issues, &String.contains?(to_string(&1), "no supported root layout"))

    ambiguous =
      project(
        extra_files: %{
          "lib/sample_app_web/alternate/root.html.heex" =>
            "<!doctype html>\n<html><body><p>alternate</p></body></html>\n"
        }
      )
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web],
        endpoint: SampleAppWeb.Endpoint
      )

    assert Enum.any?(ambiguous.issues, &String.contains?(to_string(&1), "ambiguous root layouts"))

    refute source(ambiguous, "lib/sample_app_web/components/layouts/root.html.heex") =~
             "Rekindle.Phoenix.Components.gpui_page"

    refute source(ambiguous, "lib/sample_app_web/alternate/root.html.heex") =~
             "Rekindle.Phoenix.Components.gpui_page"
  end

  test "layout parsing admits exactly one owned marker and rejects a second marker" do
    noisy_layout = """
    <!doctype html>
    <html>
      <body>
        <!-- gpui_page data-rekindle-page -->
        <p>host-owned gpui_page data-rekindle-page text</p>
      </body>
    </html>
    """

    installed =
      project(layout: noisy_layout)
      |> RekindleIgniter.install(targets: [:web], endpoint: SampleAppWeb.Endpoint)

    assert installed.issues == []

    assert count(
             source(installed, "lib/sample_app_web/components/layouts/root.html.heex"),
             "<Rekindle.Phoenix.Components.gpui_page"
           ) == 1

    marker =
      "<Rekindle.Phoenix.Components.gpui_page otp_app={:sample_app} endpoint={SampleAppWeb.Endpoint} />"

    duplicate_layout = "<html><body>#{marker}\n#{marker}</body></html>\n"
    initial = project(layout: duplicate_layout)

    rejected =
      RekindleIgniter.install(initial, targets: [:web], endpoint: SampleAppWeb.Endpoint)

    layout_path = "lib/sample_app_web/components/layouts/root.html.heex"
    assert source_issues(rejected, layout_path) != []
    assert source(rejected, layout_path) == source(initial, layout_path)

    foreign =
      project(layout: ~s(<html><body><script data-rekindle-page="v1"></script></body></html>))
      |> RekindleIgniter.install(targets: [:web], endpoint: SampleAppWeb.Endpoint)

    assert source_issues(foreign, layout_path) != []
  end

  test "documented manual installation is semantically equivalent on every owned surface" do
    automatic =
      project(deps: ~s([{:rekindle, "~> 0.1"}]))
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web, :desktop],
        endpoint: SampleAppWeb.Endpoint
      )

    manual = manual_project()

    assert automatic.issues == []
    assert manual.issues == []
    assert installation_snapshot(manual) == installation_snapshot(automatic)

    snapshot = installation_snapshot(manual)
    assert snapshot.layout =~ "host-owned"
    assert snapshot.layout =~ "Rekindle.Phoenix.Components.gpui_page"
    assert "/_build/" in snapshot.ignores
    assert :rekindle in snapshot.mix_dependencies
    assert snapshot.application_children =~ "SampleApp.HostChild"
    assert snapshot.application_children =~ "Rekindle"

    root = temp_dir!("rekindle-manual-equivalence")
    automatic_project = Path.join(root, "automatic")
    automatic_root = Path.join(root, "automatic/client")
    manual_root = Path.join(root, "manual/client")
    fixture_client = Path.join(root, "registry-fixture/rekindle-client")
    cargo_home = Path.join(root, "cargo-home")
    copy_client_fixture!(fixture_client)
    prepare_cargo_home!(cargo_home, fixture_client)
    assert_client_reconciliation_task(automatic, "client")
    {"run", ["--no-compile", "-e", expression]} = client_reconciliation_task(automatic)
    File.mkdir_p!(automatic_project)

    with_env("CARGO_HOME", cargo_home, fn ->
      with_env("CARGO_NET_OFFLINE", "true", fn ->
        File.cd!(automatic_project, fn ->
          {paths, _binding} = Code.eval_string(expression)
          assert Path.join(automatic_root, "Cargo.lock") in paths
        end)

        assert {:ok, paths} = ClientGenerator.write(manual_root, client_generator_options())
        assert Path.join(manual_root, "Cargo.lock") in paths
      end)
    end)

    assert directory_snapshot(automatic_root) == directory_snapshot(manual_root)
    automatic_lock = File.read!(Path.join(automatic_root, "Cargo.lock"))
    assert automatic_lock =~ ~s(name = "rekindle-client")
  end

  test "client path admission is project-relative and precedes every proposal mutation" do
    for invalid <- [
          "../escape",
          "/absolute",
          "client/../escape",
          "client/./nested",
          "client//nested",
          "client\\nested",
          "client\0nested",
          "client\nnested",
          "cafe\u0301",
          String.duplicate("a", 4_097),
          nil
        ] do
      initial = project()

      rejected =
        RekindleIgniter.install(initial,
          client_path: invalid,
          targets: [:web],
          endpoint: SampleAppWeb.Endpoint
        )

      assert Enum.any?(rejected.issues, &String.contains?(to_string(&1), "client_path"))
      assert rejected.tasks == initial.tasks
      assert Rewrite.sources(rejected.rewrite) == Rewrite.sources(initial.rewrite)
      assert rejected.assigns.test_files == initial.assigns.test_files
    end

    nested =
      RekindleIgniter.install(project(),
        client_path: "clients/gpui",
        targets: [:web],
        endpoint: SampleAppWeb.Endpoint
      )

    assert nested.issues == []
    assert source(nested, "clients/gpui/Cargo.toml") =~ ~s(name = "sample_app_ui")
    assert source(nested, "config/config.exs") =~ ~s(client: "clients/gpui")
    assert_client_reconciliation_task(nested, "clients/gpui")
  end

  test "symlinked client roots and ancestors fail before proposal or apply writes" do
    root = temp_dir!("rekindle-igniter-symlink-root")
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "sentinel"), "outside-owned")
    baseline = directory_snapshot(outside)

    File.cd!(root, fn ->
      for {link, client_path} <- [{"client", "client"}, {"clients", "clients/gpui"}] do
        File.ln_s!(outside, link)
        initial = project()

        rejected =
          RekindleIgniter.install(initial,
            client_path: client_path,
            targets: [:web],
            endpoint: SampleAppWeb.Endpoint
          )

        assert Enum.any?(rejected.issues, &String.contains?(to_string(&1), "symlink"))
        assert rejected.tasks == initial.tasks
        assert Rewrite.sources(rejected.rewrite) == Rewrite.sources(initial.rewrite)
        assert rejected.assigns.test_files == initial.assigns.test_files
        assert_raise RuntimeError, ~r/client_path.*symlink/, fn -> apply_igniter!(rejected) end
        assert directory_snapshot(outside) == baseline
        File.rm!(link)
      end
    end)
  end

  test "proposal-time client sources cannot follow a substituted client root" do
    root = temp_dir!("rekindle-igniter-substituted-root")
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "sentinel"), "outside-owned")
    baseline = directory_snapshot(outside)

    File.cd!(root, fn ->
      proposal =
        RekindleIgniter.install(project(),
          client_path: "client",
          targets: [:web],
          endpoint: SampleAppWeb.Endpoint
        )

      assert proposal.issues == []
      source = Rewrite.source!(proposal.rewrite, "client/Cargo.toml")
      refute Rewrite.Source.updated?(source)
      File.ln_s!(outside, "client")

      assert {:ok, _source} = Rewrite.Source.write(source, force: true)
      assert directory_snapshot(outside) == baseline

      {"run", ["--no-compile", "-e", expression]} = client_reconciliation_task(proposal)

      error = assert_raise Mix.Error, fn -> Code.eval_string(expression) end
      assert error.message == "install_conflict: generated client installation failed"

      assert directory_snapshot(outside) == baseline
    end)
  end

  test "installer lock failures are typed, bounded, and do not expose command output" do
    root = temp_dir!("rekindle-igniter-lock-failure")
    rustup = Path.join(root, "rustup")
    secret = "installer-lock-secret"

    File.write!(
      rustup,
      "#!/bin/sh\nprintf '%s\\n' '#{secret} /private/build/path' >&2\nexit 37\n"
    )

    File.chmod!(rustup, 0o700)

    proposal =
      RekindleIgniter.install(project(),
        client_path: "client",
        targets: [:web],
        endpoint: SampleAppWeb.Endpoint
      )

    {"run", ["--no-compile", "-e", expression]} = client_reconciliation_task(proposal)

    with_env("REKINDLE_RUSTUP", rustup, fn ->
      File.cd!(root, fn ->
        error = assert_raise Mix.Error, fn -> Code.eval_string(expression) end
        assert error.message == "cargo_failed: Cargo.lock generation failed with status 37"
        refute error.message =~ secret
        refute error.message =~ "/private/build/path"
        assert byte_size(error.message) < 512
        refute File.exists?(Path.join(root, "client"))
      end)
    end)
  end

  @tag timeout: 180_000
  test "applied canonical client generates a lock and checks both declared toolchains" do
    root = temp_dir!("rekindle-igniter-applied")
    client_root = Path.join(root, "client")
    fixture_client = Path.join(root, "registry-fixture/rekindle-client")
    cargo_home = Path.join(root, "cargo-home")
    copy_client_fixture!(fixture_client)
    prepare_cargo_home!(cargo_home, fixture_client)

    proposal =
      RekindleIgniter.install(project(),
        client_path: "client",
        targets: [:web, :desktop],
        endpoint: SampleAppWeb.Endpoint
      )

    assert_client_reconciliation_task(proposal, "client")
    {"run", ["--no-compile", "-e", expression]} = client_reconciliation_task(proposal)

    with_env("CARGO_HOME", cargo_home, fn ->
      with_env("CARGO_NET_OFFLINE", "true", fn ->
        File.cd!(root, fn -> Code.eval_string(expression) end)
        lock = File.read!(Path.join(client_root, "Cargo.lock"))
        assert lock =~ ~s(name = "rekindle-client")

        assert_cargo!(client_root, "1.95.0", [
          "metadata",
          "--locked",
          "--format-version",
          "1",
          "--no-deps"
        ])

        assert_cargo!(client_root, "1.95.0", [
          "check",
          "--locked",
          "--no-default-features",
          "--features",
          "desktop",
          "--bin",
          "sample_app"
        ])

        assert_cargo!(client_root, "nightly-2026-04-01", [
          "check",
          "--locked",
          "--target",
          "wasm32-unknown-unknown",
          "--no-default-features",
          "--features",
          "web",
          "--bin",
          "sample_app-web"
        ])
      end)
    end)

    reinstalled =
      client_root
      |> client_files()
      |> Enum.reduce(project(), fn {relative, contents}, igniter ->
        Igniter.create_new_file(igniter, Path.join("client", relative), contents)
      end)
      |> apply_igniter!()
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web, :desktop],
        endpoint: SampleAppWeb.Endpoint
      )

    assert reinstalled.issues == []
    assert_client_reconciliation_task(reinstalled, "client")
  end

  test "modified template-owned files conflict while application UI remains owned by the app" do
    installed =
      project()
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web, :desktop],
        endpoint: SampleAppWeb.Endpoint
      )
      |> apply_igniter!()

    editable =
      Igniter.update_file(installed, "client/src/app.rs", fn source ->
        Rewrite.Source.update(source, :content, fn _ -> "// application UI\n" end)
      end)
      |> apply_igniter!()

    assert editable
           |> RekindleIgniter.install(
             client_path: "client",
             targets: [:web, :desktop],
             endpoint: SampleAppWeb.Endpoint
           )
           |> Map.fetch!(:issues) == []

    conflicting =
      Igniter.update_file(installed, "client/src/bin/web.rs", fn source ->
        Rewrite.Source.update(source, :content, fn _ -> "fn main() {}\n" end)
      end)
      |> apply_igniter!()
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web, :desktop],
        endpoint: SampleAppWeb.Endpoint
      )

    assert Enum.any?(
             conflicting.issues,
             &String.contains?(to_string(&1), "client/src/bin/web.rs")
           )
  end

  test "propagates explicit accepted origins and validates no-client adoption" do
    client =
      Rekindle.ClientGenerator.render(
        application_id: "sample_app",
        package: "sample_app_ui",
        targets: [:web]
      )

    adopted =
      Enum.reduce(client, project(), fn {path, contents}, igniter ->
        Igniter.create_new_file(igniter, Path.join("client", path), contents)
      end)
      |> apply_igniter!()
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web],
        endpoint: SampleAppWeb.Endpoint,
        accepted_origins: ["https://example.test"],
        no_client: true
      )

    assert adopted.issues == []
    assert source(adopted, "config/dev.exs") =~ "https://example.test"

    marker = Jason.decode!(client[".rekindle-client.json"])

    for invalid_marker <- [
          Map.delete(marker, "template_version"),
          Map.put(marker, "targets", ["web"])
        ] do
      invalid_client =
        Map.put(
          client,
          ".rekindle-client.json",
          Rekindle.CanonicalValue.encode!(invalid_marker) <> "\n"
        )

      rejected =
        invalid_client
        |> Enum.reduce(project(), fn {path, contents}, igniter ->
          Igniter.create_new_file(igniter, Path.join("client", path), contents)
        end)
        |> apply_igniter!()
        |> RekindleIgniter.install(
          client_path: "client",
          targets: [:web],
          endpoint: SampleAppWeb.Endpoint,
          no_client: true
        )

      assert Enum.any?(
               rejected.issues,
               &String.contains?(to_string(&1), "structurally adoptable")
             )
    end

    marker_only =
      project()
      |> Igniter.create_new_file("client/.rekindle-client.json", client[".rekindle-client.json"])
      |> apply_igniter!()
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web],
        endpoint: SampleAppWeb.Endpoint,
        no_client: true
      )

    assert Enum.any?(
             marker_only.issues,
             &String.contains?(to_string(&1), "structurally adoptable")
           )

    tampered =
      adopted
      |> Igniter.update_file("client/src/bin/web.rs", fn source ->
        Rewrite.Source.update(source, :content, fn _ -> "fn main() {}\n" end)
      end)
      |> apply_igniter!()
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web],
        endpoint: SampleAppWeb.Endpoint,
        no_client: true
      )

    assert Enum.any?(tampered.issues, &String.contains?(to_string(&1), "structurally adoptable"))

    mismatched_client =
      Rekindle.ClientGenerator.render(
        application_id: "sample_app",
        package: "foreign_ui",
        web_binary: "foreign-web",
        targets: [:web]
      )

    mismatched =
      Enum.reduce(mismatched_client, project(), fn {path, contents}, igniter ->
        Igniter.create_new_file(igniter, Path.join("client", path), contents)
      end)
      |> apply_igniter!()
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web],
        endpoint: SampleAppWeb.Endpoint,
        no_client: true
      )

    assert Enum.any?(
             mismatched.issues,
             &String.contains?(to_string(&1), "structurally adoptable")
           )

    missing_public =
      client
      |> Map.delete("public/.gitkeep")
      |> Enum.reduce(project(), fn {path, contents}, igniter ->
        Igniter.create_new_file(igniter, Path.join("client", path), contents)
      end)
      |> apply_igniter!()
      |> RekindleIgniter.install(
        client_path: "client",
        targets: [:web],
        endpoint: SampleAppWeb.Endpoint,
        no_client: true
      )

    assert Enum.any?(
             missing_public.issues,
             &String.contains?(to_string(&1), "structurally adoptable")
           )
  end

  test "selects the only project endpoint and matches an explicit module string" do
    automatic = RekindleIgniter.install(project(), targets: [:web])
    assert automatic.issues == []
    assert source(automatic, "config/dev.exs") =~ "SampleAppWeb.Endpoint"

    explicit =
      RekindleIgniter.install(project(),
        targets: [:web],
        endpoint: "SampleAppWeb.Endpoint"
      )

    assert explicit.issues == []
    assert source(explicit, "lib/sample_app_web/endpoint.ex") =~ "Rekindle.Phoenix.Socket"
  end

  test "requires explicit selection for multiple endpoints without creating input atoms" do
    ambiguous =
      project()
      |> Igniter.create_new_file(
        "lib/admin_web/endpoint.ex",
        """
        defmodule AdminWeb.Endpoint do
          use Phoenix.Endpoint, otp_app: :sample_app
        end
        """
      )
      |> apply_igniter!()
      |> RekindleIgniter.install(targets: [:web])

    assert Enum.any?(ambiguous.issues, &String.contains?(to_string(&1), "multiple Phoenix"))

    missing = RekindleIgniter.install(project(), targets: [:web], endpoint: "Unknown.Endpoint")
    assert Enum.any?(missing.issues, &String.contains?(to_string(&1), "must match"))
  end

  test "rejects foreign Rekindle endpoint registrations and dynamic static allowlists" do
    foreign =
      project(endpoint_extra: ~s(plug Rekindle.Phoenix.DevPlug, otp_app: :other))
      |> RekindleIgniter.install(targets: [:web], endpoint: SampleAppWeb.Endpoint)

    assert Enum.any?(foreign.issues, &String.contains?(to_string(&1), "conflicting Rekindle"))

    dynamic =
      project(static_paths: "@paths")
      |> RekindleIgniter.install(targets: [:web], endpoint: SampleAppWeb.Endpoint)

    assert Enum.any?(dynamic.issues, &String.contains?(to_string(&1), "literal top-level"))
  end

  test "classifies exact owned child and alias forms without substring matches" do
    unrelated =
      project(
        children: "[SampleApp.HostChild, SampleApp.MyRekindleWorker]",
        assets_build: ~s(["cmd my_rekindle.build"])
      )
      |> RekindleIgniter.install(targets: [:web], endpoint: SampleAppWeb.Endpoint)

    assert unrelated.issues == []
    assert source(unrelated, "mix.exs") =~ ~s("cmd my_rekindle.build", "rekindle.build web")

    malformed_child =
      project(children: "[SampleApp.HostChild, {Rekindle, otp_app: :other}]")
      |> RekindleIgniter.install(targets: [:web], endpoint: SampleAppWeb.Endpoint)

    assert Enum.any?(
             malformed_child.issues,
             &String.contains?(to_string(&1), "foreign or malformed Rekindle child")
           )

    branch = """
    if Code.ensure_loaded?(Mix) and Mix.env() != :prod do
      [{Rekindle, otp_app: :sample_app, name: SampleApp.Rekindle}]
    else
      []
    end
    """

    duplicate_child =
      project(children: "([SampleApp.HostChild] ++ (#{branch})) ++ (#{branch})")
      |> RekindleIgniter.install(targets: [:web], endpoint: SampleAppWeb.Endpoint)

    assert Enum.any?(
             duplicate_child.issues,
             &String.contains?(to_string(&1), "Rekindle child forms")
           )

    for {label, options} <- [
          {:malformed_build, [assets_build: ~s(["cmd host.build", "rekindle.build desktop"])]},
          {:duplicate_build, [assets_build: ~s(["rekindle.build web", "rekindle.build web"])]},
          {:malformed_deploy, [assets_deploy: ~s(["cmd rekindle.phoenix.deploy", "phx.digest"])]}
        ] do
      initial = project(options)

      conflict =
        RekindleIgniter.install(initial, targets: [:web], endpoint: SampleAppWeb.Endpoint)

      assert source_issues(conflict, "mix.exs") != [], "#{label} should be rejected"
      assert source(conflict, "mix.exs") == source(initial, "mix.exs")
    end
  end

  test "desktop-only installation preserves all host asset aliases" do
    installed =
      project()
      |> RekindleIgniter.install(targets: [:desktop])
      |> apply_igniter!()

    mix = source(installed, "mix.exs")
    assert mix =~ ~s("assets.build": ["cmd host.build"])
    assert mix =~ ~s("assets.deploy": ["cmd host.deploy", "phx.digest"])
    refute mix =~ "rekindle.build web"
    refute mix =~ "rekindle.phoenix.deploy"
    refute source(installed, "lib/sample_app_web/endpoint.ex") =~ "Rekindle"
  end

  defp manual_project do
    client_files =
      ClientGenerator.render(
        application_id: "sample_app",
        package: "sample_app_ui",
        web_binary: "sample_app-web",
        desktop_binary: "sample_app",
        targets: [:web, :desktop]
      )
      |> Map.new(fn {path, contents} -> {Path.join("client", path), contents} end)

    config_files = %{
      "config/config.exs" => """
      import Config

      config :sample_app,
        rekindle_build: [
          schema: 1,
          client: "client",
          targets: [
            web: [
              package: "sample_app_ui",
              binary: "sample_app-web",
              toolchain: [kind: :rustup, name: "nightly-2026-04-01"],
              rust_target: "wasm32-unknown-unknown",
              features: ["web"],
              default_features: false,
              profiles: [dev: "dev", release: "release"],
              environment: [inherit: :toolchain, set: [], unset: [], build_inputs: [], redact: []],
              public: "client/public",
              hot_styles: [],
              projection: [mode: :phoenix_static, root: "priv/static/rekindle"]
            ],
            desktop: [
              package: "sample_app_ui",
              binary: "sample_app",
              toolchain: [kind: :rustup, name: "1.95.0"],
              features: ["desktop"],
              default_features: false,
              profiles: [dev: "dev", release: "release"],
              environment: [inherit: :toolchain, set: [], unset: [], build_inputs: [], redact: []],
              runtime: [
                readiness: :ipc_v1,
                startup_timeout_ms: 10_000,
                shutdown_timeout_ms: 3_000,
                replacement: :overlap,
                handoff: :enabled
              ],
              projection: [mode: :directory, root: "dist/rekindle/desktop"]
            ]
          ]
        ]

      import_config "\#{config_env()}.exs"
      """,
      "config/dev.exs" => """
      import Config

      config :sample_app,
        rekindle_dev: [
          schema: 1,
          enabled: true,
          targets: [:web],
          endpoint: SampleAppWeb.Endpoint,
          accepted_origins: :endpoint
        ]
      """
    }

    endpoint = """
    if code_reloading? do
      socket "/_rekindle/socket", Rekindle.Phoenix.Socket,
        websocket: true,
        longpoll: false

      plug Rekindle.Phoenix.DevPlug, otp_app: :sample_app
    end
    """

    children = """
    [SampleApp.HostChild] ++
      if Code.ensure_loaded?(Mix) and Mix.env() != :prod do
        [{Rekindle, otp_app: :sample_app, name: SampleApp.Rekindle}]
      else
        []
      end
    """

    layout = """
    <!doctype html>
    <html><body><p>host-owned</p>  <Rekindle.Phoenix.Components.gpui_page otp_app={:sample_app} endpoint={SampleAppWeb.Endpoint} />
    </body></html>
    """

    project(
      deps: ~s([{:rekindle, "~> 0.1"}]),
      children: children,
      static_paths: ~s(["assets", "images", "favicon.ico", "rekindle"]),
      endpoint_extra: endpoint,
      assets_build: ~s(["cmd host.build", "rekindle.build web"]),
      assets_deploy: ~s(["cmd host.deploy", "rekindle.phoenix.deploy"]),
      layout: layout,
      gitignore:
        "/_build/\n/.rekindle/\n/priv/static/rekindle/\n/dist/rekindle/desktop/\n/client/.rekindle/\n",
      extra_files: Map.merge(client_files, config_files)
    )
  end

  defp installation_snapshot(igniter) do
    elixir_paths = [
      "mix.exs",
      "config/config.exs",
      "config/dev.exs",
      "lib/sample_app/application.ex",
      "lib/sample_app_web.ex",
      "lib/sample_app_web/endpoint.ex"
    ]

    %{
      elixir:
        Map.new(elixir_paths, fn path ->
          {path, igniter |> virtual_file(path) |> normalized_ast()}
        end),
      layout:
        igniter
        |> virtual_file("lib/sample_app_web/components/layouts/root.html.heex")
        |> String.replace(~r/\s+/, " ")
        |> String.trim(),
      ignores:
        igniter
        |> virtual_file(".gitignore")
        |> String.split("\n", trim: true)
        |> Enum.sort(),
      client:
        Map.new(client_paths(), fn path ->
          {path, virtual_file(igniter, Path.join("client", path))}
        end),
      mix_dependencies:
        if(String.contains?(virtual_file(igniter, "mix.exs"), "{:rekindle,"),
          do: [:rekindle],
          else: []
        ),
      application_children:
        igniter
        |> virtual_file("lib/sample_app/application.ex")
        |> Code.string_to_quoted!()
        |> Macro.to_string()
    }
  end

  defp normalized_ast(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(fn
      {form, metadata, arguments} when is_list(metadata) -> {form, [], arguments}
      node -> node
    end)
  end

  defp project(options \\ []) do
    endpoint_extra = Keyword.get(options, :endpoint_extra, "")
    static_paths = Keyword.get(options, :static_paths, "~w(assets images favicon.ico)")
    children = Keyword.get(options, :children, "[SampleApp.HostChild]")
    deps = Keyword.get(options, :deps, "[]")
    assets_build = Keyword.get(options, :assets_build, ~s(["cmd host.build"]))

    layout =
      Keyword.get(
        options,
        :layout,
        "<!doctype html>\n<html><body><p>host-owned</p></body></html>\n"
      )

    layout_path =
      Keyword.get(options, :layout_path, "lib/sample_app_web/components/layouts/root.html.heex")

    gitignore = Keyword.get(options, :gitignore, "/_build/\n")
    extra_files = Keyword.get(options, :extra_files, %{})

    assets_deploy =
      Keyword.get(options, :assets_deploy, ~s(["cmd host.deploy", "phx.digest"]))

    files =
      %{
        "mix.exs" => """
        defmodule SampleApp.MixProject do
          use Mix.Project

          def project do
            [app: :sample_app, version: "0.1.0", elixir: "~> 1.17", deps: deps(), aliases: aliases()]
          end

          def application, do: [extra_applications: [:logger], mod: {SampleApp.Application, []}]
          defp deps, do: #{deps}

          defp aliases do
            [
              unrelated: ["cmd keep"],
              "assets.build": #{assets_build},
              "assets.deploy": #{assets_deploy}
            ]
          end
        end
        """,
        "lib/sample_app/application.ex" => """
        defmodule SampleApp.Application do
          use Application
          def start(_type, _args) do
            children = #{children}
            Supervisor.start_link(children, strategy: :one_for_one)
          end
        end
        """,
        "lib/sample_app_web.ex" => """
        defmodule SampleAppWeb do
          def static_paths, do: #{static_paths}
        end
        """,
        "lib/sample_app_web/endpoint.ex" => """
        defmodule SampleAppWeb.Endpoint do
          use Phoenix.Endpoint, otp_app: :sample_app
          #{endpoint_extra}
          plug SampleAppWeb.Router
        end
        """,
        ".gitignore" => gitignore
      }
      |> then(fn files ->
        if layout_path, do: Map.put(files, layout_path, layout), else: files
      end)
      |> Map.merge(extra_files)

    test_project(
      app_name: :sample_app,
      files: files
    )
  end

  defp source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  defp source_issues(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.issues()
  end

  defp assert_client_reconciliation_task(igniter, client_path) do
    assert {"run", ["--no-compile", "-e", expression]} = client_reconciliation_task(igniter)

    assert expression =~
             "Rekindle.ClientGenerator.run_installer_reconciliation!(#{inspect(client_path)},"
  end

  defp client_reconciliation_task(igniter) do
    Enum.find(igniter.tasks, fn
      {"run", ["--no-compile", "-e", expression]} ->
        String.starts_with?(
          expression,
          "Rekindle.ClientGenerator.run_installer_reconciliation!("
        )

      _other ->
        false
    end)
  end

  defp virtual_file(igniter, path) do
    case Rewrite.source(igniter.rewrite, path) do
      {:ok, source} -> Rewrite.Source.get(source, :content)
      {:error, _} -> Map.fetch!(igniter.assigns.test_files, path)
    end
  end

  defp client_files(client_root) do
    Map.new(client_paths(), fn relative ->
      {relative, File.read!(Path.join(client_root, relative))}
    end)
  end

  defp client_generator_options do
    [
      application_id: "sample_app",
      package: "sample_app_ui",
      web_binary: "sample_app-web",
      desktop_binary: "sample_app",
      targets: [:web, :desktop]
    ]
  end

  defp directory_snapshot(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.sort()
    |> Map.new(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
  end

  defp client_paths do
    Rekindle.ClientGenerator.render(
      application_id: "sample_app",
      package: "sample_app_ui",
      targets: [:web, :desktop]
    )
    |> Map.keys()
  end

  defp copy_client_fixture!(destination) do
    source = Path.expand("crates/rekindle-client")
    File.mkdir_p!(destination)
    File.cp!(Path.join(source, "Cargo.toml"), Path.join(destination, "Cargo.toml"))
    File.cp!(Path.join(source, "Cargo.lock"), Path.join(destination, "Cargo.lock"))
    File.cp_r!(Path.join(source, "src"), Path.join(destination, "src"))
  end

  defp prepare_cargo_home!(cargo_home, fixture_client) do
    File.mkdir_p!(cargo_home)
    upstream = Path.join(System.user_home!(), ".cargo")

    for name <- ["registry", "git"], File.exists?(Path.join(upstream, name)) do
      File.ln_s!(Path.join(upstream, name), Path.join(cargo_home, name))
    end

    File.write!(
      Path.join(cargo_home, "config.toml"),
      """
      [patch.crates-io]
      rekindle-client = { path = #{inspect(fixture_client)} }
      """
    )
  end

  defp assert_cargo!(client_root, toolchain, argv) do
    {rustc, 0} = System.cmd("rustup", ["which", "--toolchain", toolchain, "rustc"])
    target_dir = Path.expand("_build/test/generated-client-cargo/igniter/#{toolchain}")

    assert {_, 0} =
             System.cmd("rustup", ["run", toolchain, "cargo" | argv],
               cd: client_root,
               env: [{"RUSTC", String.trim(rustc)}, {"CARGO_TARGET_DIR", target_dir}],
               stderr_to_stdout: true
             )
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

  defp temp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp count(value, pattern), do: value |> String.split(pattern) |> length() |> Kernel.-(1)
  defp index(value, pattern), do: :binary.match(value, pattern) |> elem(0)
end
