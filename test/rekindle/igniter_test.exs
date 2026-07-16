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

  defp project do
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
end
