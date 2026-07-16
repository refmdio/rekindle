defmodule Rekindle.ConfigTest do
  use ExUnit.Case, async: false

  alias Rekindle.Config
  alias Rekindle.Config.{DesktopTarget, WebTarget}

  defmodule Endpoint do
  end

  defmodule Backend do
    @behaviour Rekindle.TargetBackend

    @impl true
    def backend_id, do: "test.backend"

    @impl true
    def backend_version, do: "1"

    @impl true
    def validate(_target, options), do: {:ok, options}

    @impl true
    def plan(_context, _options), do: {:error, failure()}

    @impl true
    def finalize(_context, _options, _result), do: {:error, failure()}

    defp failure do
      Rekindle.Failure.new!(
        target: nil,
        stage: :internal,
        code: :internal,
        message: "unused"
      )
    end
  end

  test "normalizes the closed canonical Web schema and every default" do
    assert {:ok, project} = Config.normalize(:demo_app, web_build(), web_dev())

    assert project.application_id == "demo_app"
    assert project.build.schema == 1
    assert project.build.client == "client"
    assert project.build.cache.root == ".rekindle/cache"
    assert project.build.cache.retained_generations == 3
    assert project.build.cache.max_generation_bytes == 2_147_483_648
    assert project.build.process.build_timeout_ms == 900_000
    assert project.build.process.max_cargo_builds == 2

    assert %WebTarget{} = web = project.build.targets.web
    assert web.package == "demo_app_ui"
    assert web.binary == "demo-app-web"
    assert web.rust_target == "wasm32-unknown-unknown"
    assert web.features == ["alpha", "web"]
    assert web.default_features == false
    assert web.profiles == %{dev: "dev", release: "release"}
    assert web.environment.inherit == :toolchain
    assert web.public == "client/public"
    assert web.hot_styles == ["styles/app.css"]
    assert web.projection == %{mode: :phoenix_static, root: "priv/static/rekindle"}

    assert project.dev.targets == [:web]
    assert project.dev.endpoint == Endpoint
    assert project.dev.accepted_origins == :endpoint
    assert project.dev.debounce_ms == 75
  end

  test "normalizes desktop runtime defaults and desktop-only development" do
    assert {:ok, project} = Config.normalize(:demo_app, desktop_build(), [])
    assert %DesktopTarget{} = desktop = project.build.targets.desktop
    assert desktop.rust_target == nil
    assert desktop.runtime.readiness == :ipc_v1
    assert desktop.runtime.replacement == :overlap
    assert desktop.runtime.handoff == :enabled
    assert project.dev.targets == [:desktop]
    assert project.dev.endpoint == nil
    assert project.dev.accepted_origins == nil
  end

  test "admits the external pipeline and forbids canonical field mixing" do
    target = [
      package: "demo_app_ui",
      binary: "demo-app-web",
      features: ["web"],
      backend: [module: Backend, options: %{"mode" => "test"}],
      projection: [mode: :phoenix_static, root: "priv/static/rekindle"]
    ]

    assert {:ok, project} =
             Config.normalize(
               :demo_app,
               [schema: 1, client: "client", targets: [web: target]],
               web_dev()
             )

    assert {:external, admission} = project.build.targets.web.backend
    assert admission.backend_id == "test.backend"
    assert admission.options == %{"mode" => "test"}

    mixed = Keyword.put(target, :toolchain, kind: :rustup, name: "nightly")

    assert_error(
      Config.normalize(
        :demo_app,
        [schema: 1, client: "client", targets: [web: mixed]],
        web_dev()
      ),
      :config_invalid
    )
  end

  test "rejects every closed-record unknown or duplicate key" do
    invalid = [
      Keyword.put(web_build(), :unknown, true),
      web_build() ++ [schema: 1],
      Keyword.update!(web_build(), :targets, &(&1 ++ [web: elem(List.first(&1), 1)])),
      Keyword.update!(web_build(), :cache, fn cache -> cache ++ [root: "other"] end),
      Keyword.update!(web_build(), :process, &Keyword.put(&1, :unknown, 1))
    ]

    for config <- invalid do
      assert_error(Config.normalize(:demo_app, config, web_dev()), :config_invalid)
    end
  end

  test "rejects missing fields, unsafe paths, and output overlap" do
    assert_error(Config.normalize(:demo_app, nil, []), :config_missing)

    assert_error(
      Config.normalize(:demo_app, Keyword.put(web_build(), :client, "../client"), web_dev()),
      :path_invalid
    )

    overlap =
      Keyword.update!(web_build(), :cache, &Keyword.put(&1, :root, "client/cache"))

    assert_error(Config.normalize(:demo_app, overlap, web_dev()), :path_overlap)

    output_overlap =
      web_build()
      |> Keyword.put(:targets, web_build()[:targets] ++ desktop_build()[:targets])
      |> Keyword.update!(:targets, fn targets ->
        Keyword.update!(targets, :desktop, fn desktop ->
          Keyword.put(desktop, :projection,
            mode: :directory,
            root: "priv/static/rekindle/desktop"
          )
        end)
      end)

    assert_error(Config.normalize(:demo_app, output_overlap, web_dev()), :path_overlap)
  end

  test "rejects incompatible runtime and development combinations" do
    invalid_runtime =
      desktop_build()
      |> Keyword.update!(:targets, fn targets ->
        Keyword.update!(targets, :desktop, fn desktop ->
          Keyword.put(desktop, :runtime,
            readiness: :startup_grace,
            startup_grace_ms: 500,
            handoff: :enabled
          )
        end)
      end)

    assert_error(Config.normalize(:demo_app, invalid_runtime, []), :config_invalid)

    assert_error(
      Config.normalize(:demo_app, web_build(), schema: 1, enabled: true, targets: [:desktop]),
      :target_undeclared
    )

    assert_error(
      Config.normalize(:demo_app, web_build(), schema: 1, enabled: true, targets: [:web]),
      :config_missing
    )

    assert_error(
      Config.normalize(:demo_app, web_build(),
        schema: 1,
        enabled: true,
        targets: [:web],
        endpoint: Endpoint,
        accepted_origins: ["https://example.com/path"]
      ),
      :config_invalid
    )
  end

  test "normalizes environment names and requires identity/redaction coverage" do
    target =
      web_target()
      |> Keyword.put(:environment,
        inherit: :none,
        set: [ZZ: {:literal, "2"}, AA: {:host, "SOURCE_TOKEN"}],
        unset: ["UNUSED"],
        build_inputs: ["ZZ", "AA"],
        redact: ["AA"]
      )

    # Environment names are strings; atoms must not be normalized implicitly.
    assert_error(
      Config.normalize(
        :demo_app,
        [schema: 1, client: "client", targets: [web: target]],
        web_dev()
      ),
      :config_invalid
    )

    target =
      Keyword.put(web_target(), :environment,
        inherit: :none,
        set: [{"ZZ", {:literal, "2"}}, {"AA", {:host, "SOURCE_TOKEN"}}],
        unset: ["UNUSED"],
        build_inputs: ["ZZ", "AA"],
        redact: ["AA"]
      )

    assert {:ok, project} =
             Config.normalize(
               :demo_app,
               [schema: 1, client: "client", targets: [web: target]],
               web_dev()
             )

    assert Enum.map(project.build.targets.web.environment.set, &elem(&1, 0)) == ["AA", "ZZ"]
  end

  test "rejects reserved, symlinked, and normalization-colliding roots" do
    assert_error(
      Config.normalize(:demo_app, Keyword.put(web_build(), :client, ".git"), web_dev()),
      :path_invalid
    )

    root = Path.join(System.tmp_dir!(), "rekindle-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.ln_s!(Path.expand("client"), Path.join(root, "client"))
    on_exit(fn -> File.rm_rf!(root) end)

    assert_error(
      Config.normalize(:demo_app, web_build(), web_dev(), project_root: root),
      :path_invalid
    )

    collision =
      web_build()
      |> Keyword.put(:targets, web_build()[:targets] ++ desktop_build()[:targets])
      |> Keyword.update!(:targets, fn targets ->
        Keyword.update!(targets, :desktop, fn desktop ->
          Keyword.put(desktop, :projection,
            mode: :directory,
            root: "PRIV/STATIC/REKINDLE"
          )
        end)
      end)

    assert_error(Config.normalize(:demo_app, collision, web_dev()), :path_overlap)
  end

  test "explicit accepted origins must intersect the endpoint policy" do
    previous = Application.get_env(:demo_app, Endpoint)
    Application.put_env(:demo_app, Endpoint, check_origin: ["https://allowed.example"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:demo_app, Endpoint, previous),
        else: Application.delete_env(:demo_app, Endpoint)
    end)

    dev = [
      schema: 1,
      enabled: true,
      targets: [:web],
      endpoint: Endpoint,
      accepted_origins: ["https://allowed.example"]
    ]

    assert {:ok, project} = Config.normalize(:demo_app, web_build(), dev)
    assert project.dev.accepted_origins == ["https://allowed.example"]

    assert_error(
      Config.normalize(:demo_app, web_build(),
        schema: 1,
        enabled: true,
        targets: [:web],
        endpoint: Endpoint,
        accepted_origins: ["https://blocked.example"]
      ),
      :config_invalid
    )
  end

  defp web_build do
    [
      schema: 1,
      client: "client",
      targets: [web: web_target()],
      cache: [root: ".rekindle/cache"],
      process: [max_cargo_builds: 2]
    ]
  end

  defp web_target do
    [
      package: "demo_app_ui",
      binary: "demo-app-web",
      toolchain: [kind: :rustup, name: "nightly-2026-04-01"],
      rust_target: "wasm32-unknown-unknown",
      features: ["web", "alpha"],
      default_features: false,
      public: "client/public",
      hot_styles: ["styles/app.css"],
      projection: [mode: :phoenix_static, root: "priv/static/rekindle"]
    ]
  end

  defp desktop_build do
    [
      schema: 1,
      client: "client",
      targets: [
        desktop: [
          package: "demo_app_ui",
          binary: "demo-app",
          toolchain: [kind: :rustup, name: "1.95.0"],
          features: ["desktop"],
          projection: [mode: :directory, root: "dist/rekindle/desktop"]
        ]
      ]
    ]
  end

  defp web_dev do
    [schema: 1, enabled: true, targets: [:web], endpoint: Endpoint]
  end

  defp assert_error(result, code) do
    assert {:error, errors} = result
    assert Enum.any?(errors, &(&1.code == code)), "expected #{code}, got: #{inspect(errors)}"
  end
end
