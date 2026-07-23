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
    assert length(Regex.scan(~r/\{Rekindle,/, application)) == 1

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

  test "rejects invalid selections before changing the project" do
    original = project()

    for options <- [[integration: "other"], [targets: ["mobile"]], [targets: []]] do
      rejected = install(original, options)

      assert rejected.issues != []
      assert changed_contents(rejected) == changed_contents(original)
    end
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
