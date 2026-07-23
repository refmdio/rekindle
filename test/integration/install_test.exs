defmodule Mix.Tasks.Phx.Server do
  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    send(Application.fetch_env!(:rekindle, :phx_server_probe), {:phx_server, arguments})
  end
end

defmodule Rekindle.InstallTest do
  use ExUnit.Case, async: false

  alias Igniter.Mix.Task.Args
  alias Igniter.Test

  test "fresh installation defaults to GPUI with both targets" do
    installed = install(project())

    assert installed.issues == []
    assert content(installed, "config/config.exs") =~ ~r/config :demo,\s+Rekindle/
    assert content(installed, "config/config.exs") =~ "integration: :gpui"
    assert content(installed, "config/config.exs") =~ "web: [features: [\"web\"]]"
    assert content(installed, "config/config.exs") =~ "desktop: [features: [\"desktop\"]]"

    assert content(installed, "client/Cargo.toml") =~ "gpui"
    assert content(installed, "client/src/lib.rs") != ""
    assert content(installed, "client/src/bin/web.rs") != ""
    assert content(installed, "client/src/bin/desktop.rs") != ""
    assert "client/public" in installed.mkdirs

    application = content(installed, "lib/demo/application.ex")
    assert application =~ "otp_app: :demo"
    assert application =~ "endpoint: DemoWeb.Endpoint"
    assert length(Regex.scan(~r/\{Rekindle,/, application)) == 1

    endpoint = content(installed, "lib/demo_web/endpoint.ex")
    assert endpoint =~ "plug(Rekindle.Web.Development, otp_app: :demo)"

    mix = content(installed, "mix.exs")
    assert mix =~ ~s(setup: ["deps.get", "rekindle.setup"])
    assert mix =~ "\"rekindle.setup\""
    assert mix =~ "\"rekindle.build web --release\""
    assert index(mix, "rekindle.build web --release") < index(mix, "phx.digest")

    assert ignore_lines(installed) == [
             "/.rekindle/",
             "/client/target/",
             "/priv/static/rekindle/",
             "/dist/rekindle/"
           ]
  end

  test "renders each integration and target selection with only enabled hooks" do
    for integration <- ~w(gpui egui slint),
        targets <- [["web"], ["desktop"], ["web", "desktop"]] do
      installed =
        install(project(),
          integration: integration,
          targets: targets
        )

      assert installed.issues == []
      manifest = content(installed, "client/Cargo.toml")
      assert manifest =~ Rekindle.Integration.dependency(String.to_existing_atom(integration))

      for target <- ~w(web desktop) do
        path = "client/src/bin/#{target}.rs"

        if target in targets do
          assert content(installed, path) != ""
        else
          refute Map.has_key?(installed.rewrite.sources, path)
        end
      end

      ignores = ignore_lines(installed)
      mix = content(installed, "mix.exs")

      if "web" in targets do
        assert "/priv/static/rekindle/" in ignores
        assert mix =~ "\"rekindle.build web --release\""
      else
        refute "/priv/static/rekindle/" in ignores
        refute mix =~ "\"rekindle.build web --release\""
      end

      if "desktop" in targets do
        assert "/dist/rekindle/" in ignores
      else
        refute "/dist/rekindle/" in ignores
      end
    end
  end

  test "repeat installation is idempotent and explicit conflicts change no files" do
    installed = install(project(), integration: "egui", targets: ["web"])
    repeated = install(installed)

    assert repeated.issues == []
    assert changed_contents(repeated) == changed_contents(installed)

    conflicted = install(installed, integration: "slint", targets: ["web"])

    assert Enum.any?(conflicted.issues, &String.contains?(&1, "conflicts"))
    assert changed_contents(conflicted) == changed_contents(installed)
  end

  test "does not stage installation when a generated client path already exists" do
    original =
      project(%{
        "client/src/lib.rs" => "pub struct Existing;\n"
      })

    rejected = install(original)

    assert Enum.any?(rejected.issues, &String.contains?(&1, "will not overwrite"))
    refute Map.has_key?(rejected.rewrite.sources, "client/Cargo.toml")
    refute content(rejected, "config/config.exs") =~ "Rekindle"
    assert content(rejected, "client/src/lib.rs") == "pub struct Existing;\n"
  end

  test "does not retain an unselected standard binary during generation" do
    original =
      project(%{
        "client/src/bin/desktop.rs" => "fn main() {}\n"
      })

    rejected = install(original, targets: ["web"])

    assert Enum.any?(rejected.issues, &String.contains?(&1, "will not overwrite"))
    assert changed_contents(rejected) == changed_contents(original)
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

  test "adopts every supported existing client without changing client files" do
    for integration <- [:gpui, :egui, :slint],
        targets <- [[:web], [:desktop], [:web, :desktop]] do
      original = existing_client(integration, targets)
      before = client_contents(original)

      adopted =
        install(original,
          integration: Atom.to_string(integration),
          targets: Enum.map(targets, &Atom.to_string/1)
        )

      assert adopted.issues == []
      assert client_contents(adopted) == before
      assert content(adopted, "config/config.exs") =~ "integration: #{inspect(integration)}"
      refute "/client/target/" in ignore_lines(adopted)
    end
  end

  test "requires both explicit selections to adopt a client" do
    original = existing_client(:gpui, [:web])

    for options <- [[], [integration: "gpui"], [targets: ["web"]]] do
      rejected = install(original, options)

      assert Enum.any?(rejected.issues, &String.contains?(&1, "required to adopt"))
      assert changed_contents(rejected) == changed_contents(original)
      assert client_contents(rejected) == client_contents(original)
    end
  end

  test "rejects mismatched, ambiguous, malformed, and incomplete clients atomically" do
    gpui = existing_client(:gpui, [:web])

    ambiguous =
      update_content(gpui, "client/Cargo.toml", fn manifest ->
        String.replace(manifest, "[dependencies]", "[dependencies]\neframe = \"0.35\"")
      end)

    malformed = update_content(gpui, "client/Cargo.toml", &("[package\n" <> &1))

    incomplete =
      %{
        gpui
        | rewrite: Rewrite.delete(gpui.rewrite, "client/src/bin/web.rs"),
          assigns:
            Map.update!(gpui.assigns, :test_files, &Map.delete(&1, "client/src/bin/web.rs"))
      }

    cases = [
      {gpui, [integration: "slint", targets: ["web"]], "does not match"},
      {ambiguous, [integration: "gpui", targets: ["web"]], "ambiguous"},
      {malformed, [integration: "gpui", targets: ["web"]], "cargo metadata failed"},
      {incomplete, [integration: "gpui", targets: ["web"]], "is required"}
    ]

    for {original, options, message} <- cases do
      rejected = install(original, options)

      assert Enum.any?(rejected.issues, &String.contains?(&1, message))
      assert changed_contents(rejected) == changed_contents(original)
      assert client_contents(rejected) == client_contents(original)
    end
  end

  test "validates target-specific dependencies for each selected target" do
    native_only =
      existing_client(:egui, [:web])
      |> update_content("client/Cargo.toml", fn manifest ->
        String.replace(
          manifest,
          ~r/\n\[target\.'cfg\(target_arch = "wasm32"\)'\.dependencies\].*?(?=\n\[\[bin\]\])/s,
          ""
        )
      end)

    impossible_web =
      existing_client(:egui, [:web])
      |> update_content("client/Cargo.toml", fn manifest ->
        String.replace(
          manifest,
          "cfg(target_arch = \"wasm32\")",
          "cfg(all(target_arch = \"wasm32\", target_os = \"windows\"))"
        )
      end)

    for original <- [native_only, impossible_web] do
      rejected = install(original, integration: "egui", targets: ["web"])

      assert Enum.any?(rejected.issues, &String.contains?(&1, "dependency for web"))
      assert changed_contents(rejected) == changed_contents(original)
    end

    host_specific =
      existing_client(:egui, [:desktop])
      |> update_content("client/Cargo.toml", fn manifest ->
        String.replace(
          manifest,
          "'cfg(not(target_arch = \"wasm32\"))'",
          "'#{host_target!()}'"
        )
      end)

    assert install(host_specific, integration: "egui", targets: ["desktop"]).issues == []
  end

  test "rejects malformed Cargo target tables without raising" do
    original =
      existing_client(:gpui, [:web])
      |> update_content("client/Cargo.toml", fn manifest ->
        manifest =
          String.replace(
            manifest,
            ~r/\n\[target\.'cfg\(target_arch = "wasm32"\)'\.dependencies\].*?(?=\n\[\[bin\]\])/s,
            ""
          )

        "target = \"invalid\"\n\n" <> manifest
      end)

    rejected = install(original, integration: "gpui", targets: ["web"])

    assert Enum.any?(rejected.issues, &String.contains?(&1, "cargo metadata failed"))
    assert changed_contents(rejected) == changed_contents(original)
  end

  test "requires selected binaries to be discoverable by Cargo" do
    disabled =
      existing_client(:slint, [:web])
      |> update_content("client/Cargo.toml", fn manifest ->
        manifest
        |> String.replace("[package]", "[package]\nautobins = false")
        |> String.replace(~r/\n\[\[bin\]\].*?required-features = \["web"\]\n/s, "\n")
      end)

    rejected = install(disabled, integration: "slint", targets: ["web"])
    assert Enum.any?(rejected.issues, &String.contains?(&1, "has no binary"))

    explicit =
      update_content(disabled, "client/Cargo.toml", fn manifest ->
        manifest <>
          """

          [[bin]]
          name = "web"
          path = "src/bin/web.rs"
          """
      end)

    assert install(explicit, integration: "slint", targets: ["web"]).issues == []
  end

  test "adopts Cargo-resolved package, binary name, and required features" do
    original =
      existing_client(:egui, [:web])
      |> update_content("client/Cargo.toml", fn manifest ->
        String.replace(
          manifest,
          """
          name = "web"
          path = "src/bin/web.rs"
          required-features = ["web"]
          """,
          """
          name = "browser"
          path = "src/bin/web.rs"
          required-features = ["web", "canvas"]
          """
        )
        |> String.replace("web = []", "web = []\ncanvas = []")
      end)

    adopted = install(original, integration: "egui", targets: ["web"])

    assert adopted.issues == []
    config = content(adopted, "config/config.exs")
    assert config =~ ~s(package: "rekindle_client")
    assert config =~ ~s(binary: "browser")
    assert config =~ ~s(features: ["web", "canvas"])
  end

  test "enables binary-required features before checking optional dependencies" do
    original =
      existing_client(:egui, [:web])
      |> update_content("client/Cargo.toml", fn manifest ->
        manifest
        |> String.replace("web = []", ~s(web = ["dep:eframe"]))
        |> String.replace(
          ~s(eframe = { version = "0.35"),
          ~s(eframe = { version = "0.35", optional = true)
        )
      end)

    adopted = install(original, integration: "egui", targets: ["web"])

    assert adopted.issues == []
    assert content(adopted, "config/config.exs") =~ ~s(features: ["web"])
  end

  test "does not accept a build-only framework dependency" do
    original =
      existing_client(:gpui, [:web])
      |> update_content("client/Cargo.toml", fn manifest ->
        String.replace(manifest, "[dependencies]", "[build-dependencies]")
      end)

    rejected = install(original, integration: "gpui", targets: ["web"])

    assert Enum.any?(rejected.issues, &String.contains?(&1, "dependency for web"))
    assert changed_contents(rejected) == changed_contents(original)
  end

  test "resolves project-relative path dependencies without changing the client" do
    original =
      existing_client(:gpui, [:web], %{
        "shared/Cargo.toml" => """
        [package]
        name = "gpui"
        version = "0.1.0"
        edition = "2024"
        """,
        "shared/src/lib.rs" => "pub struct App;\n"
      })
      |> update_content("client/Cargo.toml", fn manifest ->
        manifest
        |> String.replace(
          ~r/gpui = \{ git = [^\n]+\}/,
          ~s(gpui = { path = "../shared" })
        )
        |> String.replace(~r/gpui_platform = [^\n]+\n/, "")
      end)

    before = client_contents(original)
    root = tmp_dir()
    write_project(root, original)

    adopted =
      File.cd!(root, fn ->
        lockless = install(original, integration: "gpui", targets: ["web"])
        assert Enum.any?(lockless.issues, &String.contains?(&1, "Cargo.lock is required"))
        refute File.exists?("client/Cargo.lock")

        {_output, 0} =
          System.cmd(
            Rekindle.Toolchain.cargo_path(),
            ["generate-lockfile", "--manifest-path", "client/Cargo.toml"],
            stderr_to_stdout: true
          )

        lock = File.read!("client/Cargo.lock")
        result = install(original, integration: "gpui", targets: ["web"])
        assert File.read!("client/Cargo.lock") == lock
        result
      end)

    assert adopted.issues == []
    assert client_contents(adopted) == before
  end

  test "adopts the resolved root package from a multi-package workspace" do
    original =
      existing_client(:gpui, [:web], %{
        "client/member/Cargo.toml" => """
        [package]
        name = "member"
        version = "0.1.0"
        edition = "2024"
        """,
        "client/member/src/lib.rs" => "pub struct Member;\n"
      })
      |> update_content("client/Cargo.toml", fn manifest ->
        manifest <> "\n[workspace]\nmembers = [\"member\"]\n"
      end)

    adopted = install(original, integration: "gpui", targets: ["web"])

    assert adopted.issues == []
    assert content(adopted, "config/config.exs") =~ ~s(package: "rekindle_client")
  end

  test "rejects invalid existing configuration before staging changes" do
    installed = install(project(), integration: "egui", targets: ["web"])

    invalid_configurations = [
      update_content(installed, "config/config.exs", fn config ->
        String.replace(
          config,
          ~s(web: [features: ["web"]]),
          ~s(web: [features: :invalid])
        )
      end),
      update_content(installed, "config/config.exs", fn config ->
        String.replace(
          config,
          ~s(web: [features: ["web"]]),
          ~s(web: [features: ["web"]], web: [])
        )
      end)
    ]

    for invalid <- invalid_configurations do
      rejected = install(invalid)

      assert Enum.any?(rejected.issues, &String.contains?(&1, "not a valid static selection"))
      assert changed_contents(rejected) == changed_contents(invalid)
    end
  end

  test "rejects an existing public directory that leaves the project" do
    installed = install(project(), integration: "egui", targets: ["web"])

    invalid =
      update_content(installed, "config/config.exs", fn config ->
        String.replace(
          config,
          "integration: :egui",
          ~s(integration: :egui, public_dir: "../outside")
        )
      end)

    rejected = install(invalid)

    assert Enum.any?(rejected.issues, &String.contains?(&1, "not a valid static selection"))
    assert changed_contents(rejected) == changed_contents(invalid)
  end

  test "adoption preserves custom Cargo target configuration and ignore policy" do
    original =
      existing_client(:egui, [:desktop], %{
        "client/.cargo/config.toml" => """
        [build]
        target-dir = "../custom-target"
        """,
        ".gitignore" => "/custom-target/\n"
      })

    before = client_contents(original)
    adopted = install(original, integration: "egui", targets: ["desktop"])

    assert adopted.issues == []
    assert client_contents(adopted) == before
    assert "/custom-target/" in ignore_lines(adopted)
    refute "/client/target/" in ignore_lines(adopted)
  end

  test "uses the configured public directory for Web ignore policy" do
    original =
      existing_client(:egui, [:web])
      |> update_content("config/config.exs", fn config ->
        config <>
          """

          config :demo, Rekindle,
            integration: :egui,
            targets: [web: [features: ["web"]]],
            public_dir: "web/static"
          """
      end)

    installed = install(original)

    assert installed.issues == []
    assert "/web/static/rekindle/" in ignore_lines(installed)
    refute "/priv/static/rekindle/" in ignore_lines(installed)
  end

  test "ignore additions preserve application-owned grouping and comments" do
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
  end

  test "rekindle.dev delegates arguments to phx.server" do
    Application.put_env(:rekindle, :phx_server_probe, self())

    on_exit(fn ->
      Application.delete_env(:rekindle, :phx_server_probe)
      Mix.Task.reenable("phx.server")
      Mix.Task.reenable("rekindle.dev")
    end)

    Mix.Task.reenable("phx.server")
    Mix.Task.reenable("rekindle.dev")
    Mix.Tasks.Rekindle.Dev.run(["--open"])

    assert_receive {:phx_server, ["--open"]}
  end

  test "does not install the browser plug for a desktop-only client" do
    installed = install(project(), integration: "gpui", targets: ["desktop"])

    refute content(installed, "lib/demo_web/endpoint.ex") =~ "Rekindle.Web.Development"
  end

  defp project(extra_files \\ %{}) do
    Test.test_project(
      app_name: :demo,
      files:
        Map.merge(
          %{
            ".gitignore" => "",
            "config/config.exs" => """
            import Config
            """,
            "lib/demo/application.ex" => """
            defmodule Demo.Application do
              use Application

              @impl true
              def start(_type, _args) do
                children = [
                  Demo.Repo
                ]

                Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
              end
            end
            """,
            "lib/demo_web/endpoint.ex" => """
            defmodule DemoWeb.Endpoint do
              use Phoenix.Endpoint, otp_app: :demo
            end
            """,
            "mix.exs" => """
            defmodule Demo.MixProject do
              use Mix.Project

              def project do
                [
                  app: :demo,
                  version: "0.1.0",
                  elixir: "~> 1.17",
                  deps: deps(),
                  aliases: aliases()
                ]
              end

              def application do
                [mod: {Demo.Application, []}, extra_applications: [:logger]]
              end

              defp deps, do: []

              defp aliases do
                [
                  setup: ["deps.get"],
                  "assets.deploy": ["existing.deploy", "phx.digest"]
                ]
              end
            end
            """
          },
          extra_files
        )
    )
  end

  defp existing_client(integration, targets, extra_files \\ %{}) do
    files =
      integration
      |> Rekindle.Integration.render(targets)
      |> Map.new(fn {path, contents} -> {Path.join("client", path), contents} end)

    project(Map.merge(files, extra_files))
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

  defp client_contents(igniter) do
    igniter.rewrite.sources
    |> Enum.filter(fn {path, _source} -> String.starts_with?(path, "client/") end)
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

  defp write_project(root, igniter) do
    Enum.each(igniter.rewrite.sources, fn {relative, source} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Rewrite.Source.get(source, :content))
    end)
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-install-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp host_target! do
    {:ok, target} = Rekindle.Toolchain.host_target()
    target
  end
end
