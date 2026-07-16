defmodule Rekindle.IgniterTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Rekindle.Igniter, as: RekindleIgniter

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

    installed = apply_igniter!(proposal)

    assert Rewrite.source!(installed.rewrite, "client/Cargo.toml")
    assert source(installed, "client/src/lib.rs") =~ "rekindle_client::ClientOptions"

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

  defp project(options \\ []) do
    endpoint_extra = Keyword.get(options, :endpoint_extra, "")
    static_paths = Keyword.get(options, :static_paths, "~w(assets images favicon.ico)")

    test_project(
      app_name: :sample_app,
      files: %{
        "mix.exs" => """
        defmodule SampleApp.MixProject do
          use Mix.Project

          def project do
            [app: :sample_app, version: "0.1.0", elixir: "~> 1.17", deps: deps(), aliases: aliases()]
          end

          def application, do: [extra_applications: [:logger], mod: {SampleApp.Application, []}]
          defp deps, do: []

          defp aliases do
            [
              unrelated: ["cmd keep"],
              "assets.build": ["cmd host.build"],
              "assets.deploy": ["cmd host.deploy", "phx.digest"]
            ]
          end
        end
        """,
        "lib/sample_app/application.ex" => """
        defmodule SampleApp.Application do
          use Application
          def start(_type, _args) do
            children = [SampleApp.HostChild]
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
        "lib/sample_app_web/components/layouts/root.html.heex" => """
        <!doctype html>
        <html><body><p>host-owned</p></body></html>
        """,
        ".gitignore" => "/_build/\n"
      }
    )
  end

  defp source(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  defp count(value, pattern), do: value |> String.split(pattern) |> length() |> Kernel.-(1)
  defp index(value, pattern), do: :binary.match(value, pattern) |> elem(0)
end
