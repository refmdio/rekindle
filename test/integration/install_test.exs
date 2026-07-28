defmodule Rekindle.InstallTest do
  use ExUnit.Case, async: false

  alias Igniter.Mix.Task.Args
  alias Igniter.Test

  test "fresh installation defaults to GPUI with both targets" do
    installed = install(project())

    assert installed.issues == []
    assert content(installed, "config/config.exs") =~ "integration: :gpui"
    assert content(installed, "config/config.exs") =~ "web: []"
    assert content(installed, "config/config.exs") =~ "desktop: []"
    assert content(installed, "client/Cargo.toml") =~ "gpui"
    assert content(installed, "client/src/bin/web.rs") != ""
    assert content(installed, "client/src/bin/desktop.rs") != ""
    assert "client/public" in installed.mkdirs

    application = content(installed, "lib/demo/application.ex")
    refute application =~ "Rekindle"

    refute Map.has_key?(installed.rewrite.sources, "config/dev.exs")

    endpoint = content(installed, "lib/demo_web/endpoint.ex")
    assert endpoint =~ ~s(at: "/rekindle")
    assert endpoint =~ ~s(from: {:demo, "priv/static/rekindle"})
    assert endpoint =~ "plug(Rekindle.DevServer, otp_app: :demo)"

    assert index(endpoint, "Phoenix.CodeReloader") <
             index(endpoint, "Rekindle.DevServer")

    layout = content(installed, "lib/demo_web/components/layouts/root.html.heex")
    assert layout =~ "Rekindle.Phoenix.web_entry_path(DemoWeb.Endpoint)"
    assert layout =~ "body > canvas"
    assert layout =~ ~s|src={Rekindle.Phoenix.web_entry_path(DemoWeb.Endpoint)}>\n|
    refute layout =~ ~r/^[ \t]+$/m
    refute layout =~ "{@inner_content}"

    mix = content(installed, "mix.exs")
    assert mix =~ ~s(setup: ["deps.get", "assets.setup", "assets.build"])
    assert mix =~ ~s("assets.setup": ["existing.setup", "rekindle.setup"])
    assert mix =~ ~s("assets.build": ["existing.build", "rekindle.build web"])
    assert mix =~ ~s(precommit: ["existing.check", "rekindle.check"])
    assert index(mix, "rekindle.build web --release") < index(mix, "phx.digest")

    assert ignore_lines(installed) == [
             "/.rekindle/",
             "/client/target/",
             "/priv/static/rekindle/",
             "/dist/rekindle/"
           ]
  end

  test "renders every integration and target selection" do
    for integration <- ~w(gpui egui slint),
        targets <- [["web"], ["desktop"], ["web", "desktop"]] do
      installed = install(project(), integration: integration, targets: targets)
      assert installed.issues == []

      manifest = content(installed, "client/Cargo.toml")
      assert manifest =~ Rekindle.Integration.dependency(String.to_existing_atom(integration))
      assert content(installed, "client/Cargo.lock") =~ ~s(name = "client")

      for target <- ~w(web desktop) do
        path = "client/src/bin/#{target}.rs"

        if target in targets do
          assert content(installed, path) != ""
        else
          refute Map.has_key?(installed.rewrite.sources, path)
        end
      end

      endpoint = content(installed, "lib/demo_web/endpoint.ex")
      layout = content(installed, "lib/demo_web/components/layouts/root.html.heex")

      if "web" in targets do
        assert endpoint =~ "Rekindle.DevServer"
        assert layout =~ "Rekindle.Phoenix.web_entry_path"
        assert layout =~ ~s(<style data-rust-ui="#{integration}">)
        refute layout =~ "{@inner_content}"

        host = Rekindle.Integration.host(String.to_existing_atom(integration))
        if host != "", do: assert(layout =~ host)
      else
        refute endpoint =~ "Rekindle.DevServer"
        refute layout =~ "Rekindle"
        assert layout =~ "{@inner_content}"
      end

      refute Map.has_key?(installed.rewrite.sources, "config/dev.exs")
    end
  end

  test "repeat installation is idempotent and rejects conflicting selection" do
    installed = install(project(), integration: "egui", targets: ["web"])
    repeated = install(installed)

    assert repeated.issues == []
    assert changed_contents(repeated) == changed_contents(installed)

    conflicted = install(installed, integration: "slint", targets: ["web"])
    assert Enum.any?(conflicted.issues, &String.contains?(&1, "conflicts"))
    assert changed_contents(conflicted) == changed_contents(installed)
  end

  test "adds a target to an installed client without replacing shared UI files" do
    installed = install(project(), integration: "egui", targets: ["web"])

    installed =
      update_content(installed, "config/config.exs", fn config ->
        String.replace(config, "web: []", ~s(web: [features: ["browser"]]))
      end)

    shared_ui = content(installed, "client/src/app.rs")

    extended =
      install(installed, integration: "egui", targets: ["web", "desktop"])

    assert extended.issues == []
    assert content(extended, "config/config.exs") =~ ~s(web: [features: ["browser"]])
    assert content(extended, "config/config.exs") =~ "desktop: []"
    assert content(extended, "client/src/app.rs") == shared_ui
    assert content(extended, "client/src/bin/desktop.rs") != ""
    assert content(extended, "client/Cargo.toml") =~ ~s(name = "desktop")

    repeated = install(extended, integration: "egui", targets: ["web", "desktop"])
    assert repeated.issues == []
    assert changed_contents(repeated) == changed_contents(extended)
  end

  test "does not remove an installed target" do
    installed = install(project(), integration: "egui", targets: ["web", "desktop"])
    rejected = install(installed, integration: "egui", targets: ["web"])

    assert Enum.any?(rejected.issues, &String.contains?(&1, "conflicts"))
    assert changed_contents(rejected) == changed_contents(installed)
  end

  test "rejects target addition when the Cargo package name is not static" do
    installed = install(project(), integration: "egui", targets: ["web"])

    invalid =
      update_content(installed, "client/Cargo.toml", fn manifest ->
        String.replace(manifest, ~s(name = "client"), "name = workspace.package.name")
      end)

    rejected = install(invalid, integration: "egui", targets: ["web", "desktop"])

    assert rejected.issues == ["client/Cargo.toml must contain a static package name"]
    assert changed_contents(rejected) == changed_contents(invalid)
  end

  test "accepts quoted static Cargo package names when adding a target" do
    installed = install(project(), integration: "egui", targets: ["web"])

    customized =
      update_content(installed, "client/Cargo.toml", fn manifest ->
        String.replace(manifest, ~s(name = "client"), "name = 'custom-client' # application UI")
      end)

    extended = install(customized, integration: "egui", targets: ["web", "desktop"])

    assert extended.issues == []
    assert content(extended, "client/src/bin/desktop.rs") =~ "custom_client::TemplateApp"
  end

  test "rejects an incompatible existing Cargo bin when adding a target" do
    installed = install(project(), integration: "egui", targets: ["web"])

    customized =
      update_content(installed, "client/Cargo.toml", fn manifest ->
        manifest <>
          """

          [[bin]]
          name = "desktop"
          path = "src/custom_desktop.rs"
          required-features = ["desktop"]
          """
      end)

    rejected = install(customized, integration: "egui", targets: ["web", "desktop"])

    assert rejected.issues == [
             "client/Cargo.toml already defines desktop with a non-canonical bin configuration"
           ]

    assert changed_contents(rejected) == changed_contents(customized)
  end

  test "adds a missing static plug without duplicating the development plug" do
    installed =
      install(
        project(%{
          "lib/demo_web/endpoint.ex" => """
          defmodule DemoWeb.Endpoint do
            use Phoenix.Endpoint, otp_app: :demo

            if code_reloading? do
              plug Phoenix.CodeReloader
              plug Rekindle.DevServer, otp_app: :demo
            end

            plug DemoWeb.Router
          end
          """
        })
      )

    endpoint = content(installed, "lib/demo_web/endpoint.ex")
    assert endpoint =~ "plug(Plug.Static"
    assert length(Regex.scan(~r/Rekindle\.DevServer/, endpoint)) == 1
  end

  test "adds missing integration host markup independently from the script" do
    script =
      ~s|<script type="module" src={Rekindle.Phoenix.web_entry_path(DemoWeb.Endpoint)}></script>|

    installed =
      install(
        project(%{
          "lib/demo_web/components/layouts/root.html.heex" => """
          <html>
            <head></head>
            <body>
              #{script}
            </body>
          </html>
          """
        }),
        integration: "egui",
        targets: ["web"]
      )

    assert installed.issues == []
    layout = content(installed, "lib/demo_web/components/layouts/root.html.heex")
    assert length(Regex.scan(~r/<canvas id="the_canvas_id"><\/canvas>/, layout)) == 1
    assert length(Regex.scan(~r/Rekindle\.Phoenix\.web_entry_path/, layout)) == 1
  end

  test "requires a body insertion point before changing the project" do
    original =
      project(%{
        "lib/demo_web/components/layouts/root.html.heex" => "<html><head></head></html>\n"
      })

    rejected = install(original, integration: "egui", targets: ["web"])

    assert Enum.any?(rejected.issues, &String.contains?(&1, "must contain </body>"))
    assert changed_contents(rejected) == changed_contents(original)
  end

  test "requires a head insertion point before changing the project" do
    original =
      project(%{
        "lib/demo_web/components/layouts/root.html.heex" => "<html><body></body></html>\n"
      })

    rejected = install(original, integration: "egui", targets: ["web"])

    assert Enum.any?(rejected.issues, &String.contains?(&1, "must contain </head>"))
    assert changed_contents(rejected) == changed_contents(original)
  end

  test "rejects an unmanaged Rust client without modifying it" do
    original =
      project(%{
        "client/Cargo.toml" => "[package]\nname = \"existing\"\nversion = \"0.1.0\"\n",
        "client/src/lib.rs" => "pub struct Existing;\n"
      })

    rejected = install(original, integration: "gpui", targets: ["web"])
    assert rejected.issues == ["client/Cargo.toml already exists; Rekindle will not overwrite it"]
    assert changed_contents(rejected) == changed_contents(original)
  end

  test "does not stage installation when a generated client path already exists" do
    original = project(%{"client/src/lib.rs" => "pub struct Existing;\n"})
    rejected = install(original)

    assert Enum.any?(rejected.issues, &String.contains?(&1, "will not overwrite"))
    refute Map.has_key?(rejected.rewrite.sources, "client/Cargo.toml")
    assert content(rejected, "client/src/lib.rs") == "pub struct Existing;\n"
  end

  test "preserves an entry for a target that is not being generated" do
    original =
      project(%{
        "client/src/bin/desktop.rs" => "fn main() { println!(\"existing\"); }\n"
      })

    installed = install(original, integration: "gpui", targets: ["web"])

    assert installed.issues == []

    assert content(installed, "client/src/bin/desktop.rs") ==
             content(original, "client/src/bin/desktop.rs")

    assert content(installed, "client/src/bin/web.rs") != ""
  end

  test "rejects invalid selections before changing the project" do
    original = project()

    for options <- [[integration: "other"], [targets: ["mobile"]], [targets: []]] do
      rejected = install(original, options)
      assert rejected.issues != []
      assert changed_contents(rejected) == changed_contents(original)
    end
  end

  test "requires a Phoenix endpoint before changing the project" do
    original =
      project()
      |> then(fn igniter ->
        %{
          igniter
          | rewrite: Rewrite.delete(igniter.rewrite, "lib/demo_web/endpoint.ex"),
            assigns:
              Map.update!(
                igniter.assigns,
                :test_files,
                &Map.delete(&1, "lib/demo_web/endpoint.ex")
              )
        }
      end)

    rejected = install(original)
    assert Enum.any?(rejected.issues, &String.contains?(&1, "requires a Phoenix endpoint"))
    assert changed_contents(rejected) == changed_contents(original)
  end

  test "rejects invalid existing Rekindle configuration" do
    installed = install(project(), integration: "egui", targets: ["web"])

    invalid =
      update_content(installed, "config/config.exs", fn config ->
        String.replace(config, ~s(web: []), ~s(web: [features: :invalid]))
      end)

    rejected = install(invalid)
    assert Enum.any?(rejected.issues, &String.contains?(&1, "not a valid static selection"))
    assert changed_contents(rejected) == changed_contents(invalid)
  end

  test "ignore additions preserve existing content" do
    original =
      project(%{
        ".gitignore" => """
        # Elixir
        /_build/

        # Editor
        /.lexical/
        """
      })

    installed = install(original, integration: "egui", targets: ["web"])

    assert content(installed, ".gitignore") ==
             """
             # Elixir
             /_build/

             # Editor
             /.lexical/
             /.rekindle/
             /client/target/
             /priv/static/rekindle/
             """

    assert content(install(installed), ".gitignore") == content(installed, ".gitignore")

    without_cargo_target =
      update_content(installed, ".gitignore", &String.replace(&1, "/client/target/\n", ""))

    assert "/client/target/" in ignore_lines(install(without_cargo_target))
  end

  test "desktop-only installation does not add browser hooks" do
    installed = install(project(), integration: "gpui", targets: ["desktop"])
    refute content(installed, "lib/demo_web/endpoint.ex") =~ "Rekindle.DevServer"
    refute content(installed, "lib/demo_web/components/layouts/root.html.heex") =~ "Rekindle"
  end

  defp project(extra_files \\ %{}) do
    Test.test_project(
      app_name: :demo,
      files:
        Map.merge(
          %{
            ".gitignore" => "",
            "config/config.exs" => "import Config\n",
            "lib/demo/application.ex" => """
            defmodule Demo.Application do
              use Application

              def start(_type, _args) do
                children = [Demo.Repo]
                Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
              end
            end
            """,
            "lib/demo_web/endpoint.ex" => """
            defmodule DemoWeb.Endpoint do
              use Phoenix.Endpoint, otp_app: :demo

              if code_reloading? do
                plug Phoenix.CodeReloader
              end

              plug DemoWeb.Router
            end
            """,
            "lib/demo_web/components/layouts.ex" => """
            defmodule DemoWeb.Layouts do
              use Phoenix.Component
              embed_templates "layouts/*"
            end
            """,
            "lib/demo_web/components/layouts/root.html.heex" => """
            <!DOCTYPE html>
            <html lang="en">
              <head></head>
              <body>
                {@inner_content}
              </body>
            </html>
            """,
            "mix.exs" => """
            defmodule Demo.MixProject do
              use Mix.Project

              def project do
                [app: :demo, version: "0.1.0", deps: deps(), aliases: aliases()]
              end

              def application, do: [mod: {Demo.Application, []}]
              defp deps, do: []

              defp aliases do
                [
                  setup: ["deps.get", "assets.setup", "assets.build"],
                  "assets.setup": ["existing.setup"],
                  "assets.build": ["existing.build"],
                  "assets.deploy": ["existing.deploy", "phx.digest"],
                  precommit: ["existing.check"]
                ]
              end
            end
            """
          },
          extra_files
        )
    )
  end

  defp install(igniter, options \\ []) do
    igniter
    |> Map.put(:args, %Args{options: options})
    |> Mix.Tasks.Rekindle.Install.igniter()
  end

  defp content(igniter, path) do
    igniter.rewrite.sources[path]
    |> Rewrite.Source.get(:content)
  end

  defp changed_contents(igniter) do
    igniter.rewrite.sources
    |> Enum.filter(fn {_path, source} -> Rewrite.Source.updated?(source) end)
    |> Map.new(fn {path, source} -> {path, Rewrite.Source.get(source, :content)} end)
  end

  defp update_content(igniter, path, update) do
    source = igniter.rewrite.sources[path]

    source =
      Rewrite.Source.update(source, :content, update.(Rewrite.Source.get(source, :content)))

    %{igniter | rewrite: Rewrite.update!(igniter.rewrite, source)}
  end

  defp ignore_lines(igniter) do
    igniter
    |> content(".gitignore")
    |> String.split("\n", trim: true)
  end

  defp index(content, value) do
    {index, _length} = :binary.match(content, value)
    index
  end
end
