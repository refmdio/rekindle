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
    assert project.build.client == "lib"
    assert project.build.cache.root == ".rekindle/cache"
    assert project.build.cache.retained_generations == 3
    assert project.build.cache.max_generation_bytes == 2_147_483_648
    assert project.build.process.build_timeout_ms == 900_000
    assert project.build.process.terminate_grace_ms == 3_000
    assert project.build.process.kill_grace_ms == 2_000
    assert project.build.process.output_bytes_per_stream == 16_777_216
    assert project.build.process.max_cargo_builds == 2
    assert project.build.process.max_helper_jobs == min(System.schedulers_online(), 4)

    assert %WebTarget{} = web = project.build.targets.web
    assert web.package == "demo_app_ui"
    assert web.binary == "demo-app-web"
    assert web.rust_target == "wasm32-unknown-unknown"
    assert web.features == ["alpha", "web"]
    assert web.default_features == false
    assert web.profiles == %{dev: "dev", release: "release"}
    assert web.environment.inherit == :toolchain
    assert web.public == "test"
    assert web.hot_styles == ["styles/app.css"]
    assert web.projection == %{mode: :phoenix_static, root: "priv/static/rekindle"}

    assert project.dev.targets == [:web]
    assert project.dev.endpoint == Endpoint
    assert project.dev.accepted_origins == :endpoint
    assert project.dev.debounce_ms == 75
    assert project.dev.diagnostic_limit == 512
    assert project.dev.browser_message_bytes == 1_048_576
    assert project.dev.browser_startup_timeout_ms == 15_000
    assert project.dev.handoff_bytes == 1_048_576
    assert project.dev.snapshot_timeout_ms == 1_000
    assert project.dev.restore_timeout_ms == 1_000
  end

  test "normalizes desktop runtime defaults and desktop-only development" do
    assert {:ok, project} = Config.normalize(:demo_app, desktop_build(), [])
    assert %DesktopTarget{} = desktop = project.build.targets.desktop
    assert desktop.rust_target == nil
    assert desktop.runtime.readiness == :ipc_v1
    assert desktop.runtime.startup_timeout_ms == 10_000
    assert desktop.runtime.shutdown_timeout_ms == 3_000
    assert desktop.runtime.replacement == :overlap
    assert desktop.runtime.handoff == :enabled
    assert desktop.runtime.startup_grace_ms == nil
    assert project.dev.targets == [:desktop]
    assert project.dev.endpoint == nil
    assert project.dev.accepted_origins == nil
  end

  test "enforces every configurable resource boundary inclusively" do
    cases = [
      {:cache, :retained_generations, 1, 20},
      {:cache, :max_generation_bytes, 67_108_864, 17_179_869_184},
      {:process, :build_timeout_ms, 1_000, 3_600_000},
      {:process, :terminate_grace_ms, 0, 30_000},
      {:process, :kill_grace_ms, 100, 30_000},
      {:process, :output_bytes_per_stream, 1_048_576, 268_435_456},
      {:process, :max_cargo_builds, 1, 16},
      {:process, :max_helper_jobs, 1, 16},
      {:runtime, :startup_timeout_ms, 100, 120_000},
      {:runtime, :startup_grace_ms, 100, 30_000},
      {:runtime, :shutdown_timeout_ms, 100, 30_000},
      {:dev, :debounce_ms, 0, 2_000},
      {:dev, :diagnostic_limit, 1, 4_096},
      {:dev, :browser_message_bytes, 65_536, 4_194_304},
      {:dev, :browser_startup_timeout_ms, 1_000, 120_000},
      {:dev, :handoff_bytes, 0, 16_777_216},
      {:dev, :snapshot_timeout_ms, 100, 10_000},
      {:dev, :restore_timeout_ms, 100, 10_000}
    ]

    for {scope, field, minimum, maximum} <- cases do
      for value <- [minimum, maximum] do
        {build, dev} = resource_config(scope, field, value)
        assert {:ok, project} = Config.normalize(:demo_app, build, dev)
        assert resource_value(project, scope, field) == value
      end

      for value <- [minimum - 1, maximum + 1] do
        {build, dev} = resource_config(scope, field, value)
        assert_error(Config.normalize(:demo_app, build, dev), :config_invalid)
      end
    end
  end

  test "enforces feature count and aggregate encoded-byte boundaries" do
    below = feature_vector(128, 64) |> List.update_at(-1, &binary_part(&1, 0, 63))
    boundary = feature_vector(128, 64)
    above = List.update_at(boundary, -1, &(&1 <> "x"))

    assert Enum.sum(Enum.map(below, &byte_size/1)) == 8_191
    assert Enum.sum(Enum.map(boundary, &byte_size/1)) == 8_192
    assert Enum.sum(Enum.map(above, &byte_size/1)) == 8_193

    for features <- [below, boundary] do
      assert {:ok, project} =
               Config.normalize(:demo_app, put_web_features(features), web_dev())

      assert project.build.targets.web.features == Enum.sort(features)
    end

    assert_error(Config.normalize(:demo_app, put_web_features(above), web_dev()), :config_invalid)

    assert_error(
      Config.normalize(:demo_app, put_web_features(feature_vector(129, 8)), web_dev()),
      :config_invalid
    )
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
               [schema: 1, client: "lib", targets: [web: target]],
               web_dev()
             )

    assert {:external, admission} = project.build.targets.web.backend
    assert admission.backend_id == "test.backend"
    assert admission.options == %{"mode" => "test"}

    mixed = Keyword.put(target, :toolchain, kind: :rustup, name: "nightly")

    assert_error(
      Config.normalize(
        :demo_app,
        [schema: 1, client: "lib", targets: [web: mixed]],
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

  test "every public configuration collection rejects improper and oversized lists without raising" do
    improper = ["value" | :improper_tail]

    external_target = [
      package: "demo_app_ui",
      binary: "demo-app-web",
      features: ["web"],
      backend: [module: Backend, options: %{"nested" => improper}],
      projection: [mode: :phoenix_static, root: "priv/static/rekindle"]
    ]

    cases = [
      {:build_record, [{:schema, 1} | :improper_tail], web_dev(), []},
      {:targets, Keyword.put(web_build(), :targets, [{:web, web_target()} | :improper_tail]),
       web_dev(), []},
      {:target_record,
       put_web_target(web_build(), fn _ -> [{:package, "demo_app_ui"} | :bad] end), web_dev(),
       []},
      {:features, put_web_target(web_build(), &Keyword.put(&1, :features, improper)), web_dev(),
       []},
      {:hot_styles, put_web_target(web_build(), &Keyword.put(&1, :hot_styles, improper)),
       web_dev(), []},
      {:toolchain,
       put_web_target(web_build(), &Keyword.put(&1, :toolchain, [{:kind, :rustup} | :bad])),
       web_dev(), []},
      {:profiles,
       put_web_target(web_build(), &Keyword.put(&1, :profiles, [{:dev, "dev"} | :bad])),
       web_dev(), []},
      {:environment_record,
       put_web_target(web_build(), &Keyword.put(&1, :environment, [{:inherit, :none} | :bad])),
       web_dev(), []},
      {:environment_set,
       put_web_target(
         web_build(),
         &Keyword.put(&1, :environment, set: [{"A", {:literal, "1"}} | :bad])
       ), web_dev(), []},
      {:environment_unset,
       put_web_target(web_build(), &Keyword.put(&1, :environment, unset: improper)), web_dev(),
       []},
      {:environment_build_inputs,
       put_web_target(web_build(), &Keyword.put(&1, :environment, build_inputs: improper)),
       web_dev(), []},
      {:environment_redact,
       put_web_target(web_build(), &Keyword.put(&1, :environment, redact: improper)), web_dev(),
       []},
      {:projection,
       put_web_target(
         web_build(),
         &Keyword.put(&1, :projection, [{:mode, :phoenix_static} | :bad])
       ), web_dev(), []},
      {:cache, Keyword.put(web_build(), :cache, [{:root, ".rekindle/cache"} | :bad]), web_dev(),
       []},
      {:process, Keyword.put(web_build(), :process, [{:max_cargo_builds, 2} | :bad]), web_dev(),
       []},
      {:backend_options, Keyword.put(web_build(), :targets, web: external_target), web_dev(), []},
      {:runtime,
       put_desktop_target(
         desktop_build(),
         &Keyword.put(&1, :runtime, [{:readiness, :ipc_v1} | :bad])
       ), [], []},
      {:dev_record, web_build(), [{:schema, 1} | :bad], []},
      {:dev_targets, web_build(), Keyword.put(web_dev(), :targets, [:web | :bad]), []},
      {:accepted_origins, web_build(),
       Keyword.put(web_dev(), :accepted_origins, ["https://example.com" | :bad]), []},
      {:options, web_build(), web_dev(), [{:project_root, File.cwd!()} | :bad]},
      {:oversized,
       put_web_target(web_build(), &Keyword.put(&1, :features, List.duplicate("web", 129))),
       web_dev(), []}
    ]

    for {_label, build, dev, options} <- cases do
      assert_error(Config.normalize(:demo_app, build, dev, options), :config_invalid)
    end

    previous = Application.get_env(:demo_app, Endpoint)
    Application.put_env(:demo_app, Endpoint, check_origin: ["https://example.com" | :bad])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:demo_app, Endpoint, previous),
        else: Application.delete_env(:demo_app, Endpoint)
    end)

    assert_error(
      Config.normalize(
        :demo_app,
        web_build(),
        Keyword.put(web_dev(), :accepted_origins, ["https://example.com"])
      ),
      :config_invalid
    )

    Application.put_env(:demo_app, Endpoint, [{:check_origin, false} | :bad])

    assert_error(
      Config.normalize(
        :demo_app,
        web_build(),
        Keyword.put(web_dev(), :accepted_origins, ["https://example.com"])
      ),
      :config_invalid
    )
  end

  test "rejects missing fields, unsafe paths, and output overlap" do
    assert_error(Config.normalize(:demo_app, nil, []), :config_missing)

    assert_error(
      Config.normalize(:demo_app, Keyword.put(web_build(), :client, "../client"), web_dev()),
      :path_invalid
    )

    overlap =
      Keyword.update!(web_build(), :cache, &Keyword.put(&1, :root, "lib/cache"))

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

  test "project root admission always returns a typed result" do
    root =
      Path.join(System.tmp_dir!(), "rekindle-project-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    file = root <> "-file"
    File.write!(file, "not a directory")
    missing = root <> "-missing"

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm(file)
    end)

    for invalid <- [
          123,
          nil,
          <<255>>,
          "bad\0root",
          "bad\nroot",
          "cafe\u0301",
          String.duplicate("a", 4_097),
          missing,
          file,
          "/"
        ] do
      assert_error(
        Config.normalize(:demo_app, web_build(), web_dev(), project_root: invalid),
        :path_invalid
      )
    end

    assert {:ok, project} =
             Config.normalize(:demo_app, web_build(), web_dev(), project_root: root)

    assert project.project_root == Path.expand(root)
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
        [schema: 1, client: "lib", targets: [web: target]],
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
               [schema: 1, client: "lib", targets: [web: target]],
               web_dev()
             )

    assert Enum.map(project.build.targets.web.environment.set, &elem(&1, 0)) == ["AA", "ZZ"]
  end

  test "rejects reserved, symlinked, and normalization-colliding roots" do
    assert_error(
      Config.normalize(:demo_app, Keyword.put(web_build(), :client, ".git"), web_dev()),
      :path_invalid
    )

    for reserved_equivalent <- [".GIT", "ＤＩＳＴ", "ＰＲＩＶ/ＳＴＡＴＩＣ"] do
      assert {:error, errors} =
               Config.normalize(
                 :demo_app,
                 Keyword.put(web_build(), :client, reserved_equivalent),
                 web_dev()
               )

      assert Enum.any?(errors, &(&1.code in [:path_invalid, :path_overlap]))
    end

    root = Path.join(System.tmp_dir!(), "rekindle-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "test"))
    File.ln_s!(Path.expand("lib"), Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)

    assert_error(
      Config.normalize(:demo_app, web_build(), web_dev(), project_root: root),
      :path_invalid
    )

    real_root =
      Path.join(System.tmp_dir!(), "rekindle-real-#{System.unique_integer([:positive])}")

    linked_root = real_root <> "-link"
    File.mkdir_p!(real_root)
    File.mkdir_p!(Path.join(real_root, "lib"))
    File.mkdir_p!(Path.join(real_root, "test"))
    File.ln_s!(real_root, linked_root)

    on_exit(fn ->
      File.rm_rf!(real_root)
      File.rm(linked_root)
    end)

    assert_error(
      Config.normalize(:demo_app, web_build(), web_dev(), project_root: linked_root),
      :path_invalid
    )

    ancestor_link =
      Path.join(System.tmp_dir!(), "rekindle-ancestor-#{System.unique_integer([:positive])}")

    nested_root = Path.join(ancestor_link, "project")
    File.mkdir_p!(Path.join(real_root, "project"))
    File.mkdir_p!(Path.join(real_root, "project/lib"))
    File.mkdir_p!(Path.join(real_root, "project/test"))
    File.ln_s!(real_root, ancestor_link)
    on_exit(fn -> File.rm(ancestor_link) end)

    assert_error(
      Config.normalize(:demo_app, web_build(), web_dev(), project_root: nested_root),
      :path_invalid
    )

    file_root =
      Path.join(System.tmp_dir!(), "rekindle-file-root-#{System.unique_integer([:positive])}")

    File.write!(file_root, "not a directory")
    on_exit(fn -> File.rm(file_root) end)

    assert_error(
      Config.normalize(:demo_app, web_build(), web_dev(), project_root: file_root),
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

    case_overlap =
      web_build()
      |> Keyword.put(:client, "CLIENT")
      |> Keyword.put(:cache, root: "client/cache")

    File.mkdir_p!(Path.join(root, "CLIENT"))

    assert_error(
      Config.normalize(:demo_app, case_overlap, web_dev(), project_root: root),
      :path_overlap
    )

    source_file = Path.join(root, "source-file")
    File.write!(source_file, "not a directory")

    assert_error(
      Config.normalize(
        :demo_app,
        Keyword.put(web_build(), :client, "source-file"),
        web_dev(),
        project_root: root
      ),
      :path_invalid
    )
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
      accepted_origins: ["HTTPS://ALLOWED.EXAMPLE:443"]
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

    Application.put_env(:demo_app, Endpoint, check_origin: ["//*.example.com"])

    assert {:ok, wildcard_project} =
             Config.normalize(:demo_app, web_build(),
               schema: 1,
               enabled: true,
               targets: [:web],
               endpoint: Endpoint,
               accepted_origins: ["https://app.example.com"]
             )

    assert wildcard_project.dev.accepted_origins == ["https://app.example.com"]

    assert {:ok, _} =
             Config.normalize(
               :demo_app,
               web_build(),
               Keyword.put(dev, :accepted_origins, ["https://example.com"])
             )

    Application.put_env(:demo_app, Endpoint, check_origin: ["https://example.com:8443/"])

    assert_error(
      Config.normalize(
        :demo_app,
        web_build(),
        Keyword.put(dev, :accepted_origins, ["https://example.com:9443"])
      ),
      :config_invalid
    )

    Application.put_env(:demo_app, Endpoint, check_origin: ["https://example.com"])

    assert_error(
      Config.normalize(
        :demo_app,
        web_build(),
        Keyword.put(dev, :accepted_origins, ["https://example.com:9443"])
      ),
      :config_invalid
    )

    Application.put_env(:demo_app, Endpoint, check_origin: ["//example.com:8443/socket"])

    assert_error(
      Config.normalize(
        :demo_app,
        web_build(),
        Keyword.put(dev, :accepted_origins, ["https://example.com:9443"])
      ),
      :config_invalid
    )
  end

  test "accepted origins are canonical HTTP authorities even when endpoint checks are disabled" do
    previous = Application.get_env(:demo_app, Endpoint)
    Application.put_env(:demo_app, Endpoint, check_origin: false)

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
      accepted_origins: [
        "HTTPS://EXAMPLE.COM:443",
        "http://example.com:80",
        "https://example.com:8443",
        "https://127.0.0.1:8443",
        "https://[0:0:0:0:0:0:0:1]:443",
        "http://[2001:0db8:0:0:0:0:0:1]:8080"
      ]
    ]

    assert {:ok, project} = Config.normalize(:demo_app, web_build(), dev)

    assert project.dev.accepted_origins ==
             Enum.sort([
               "https://example.com",
               "http://example.com",
               "https://example.com:8443",
               "https://127.0.0.1:8443",
               "https://[::1]",
               "http://[2001:db8::1]:8080"
             ])

    invalid_origins = [
      <<"http://", 255>>,
      "https://cafe\u0301.example",
      "https://user@example.com",
      "https:// example.com",
      "https://example .com",
      "https://exa%20mple.com",
      "https://example.com/path",
      "https://example.com?query",
      "https://example.com#fragment",
      "https://[:::1]",
      "https://::1",
      "https://[::1",
      "https://example.com:",
      "https://example.com:0",
      "https://example.com:65536",
      "https://example.com:99999",
      "https://example.com:-1",
      "https://999.999.999.999",
      "https://127.1",
      "https://127.0.1",
      "https://001.002.003.004",
      "https://2130706433",
      "https://1.2.3",
      "https://0x7f.0.0.1",
      "https://0x7f000001",
      "https://0177.0.0.1",
      "https://-example.com",
      "https://example-.com"
    ]

    Enum.each(invalid_origins, fn origin ->
      assert_error(
        Config.normalize(
          :demo_app,
          web_build(),
          Keyword.put(dev, :accepted_origins, [origin])
        ),
        :config_invalid
      )
    end)

    Application.put_env(:demo_app, Endpoint, check_origin: ["//127.0.0.1"])

    for legacy <- [
          "https://127.1",
          "https://001.002.003.004",
          "https://2130706433",
          "https://0x7f.0.0.1",
          "https://0177.0.0.1"
        ] do
      assert_error(
        Config.normalize(
          :demo_app,
          web_build(),
          Keyword.put(dev, :accepted_origins, [legacy])
        ),
        :config_invalid
      )
    end
  end

  test "endpoint origin policies use the same exact authority grammar" do
    previous = Application.get_env(:demo_app, Endpoint)

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
      accepted_origins: ["https://[0:0:0:0:0:0:0:1]:443"]
    ]

    Application.put_env(:demo_app, Endpoint, check_origin: ["https://[::1]"])
    assert {:ok, project} = Config.normalize(:demo_app, web_build(), dev)
    assert project.dev.accepted_origins == ["https://[::1]"]

    ipv4_dev = Keyword.put(dev, :accepted_origins, ["https://127.0.0.1"])

    for legacy_policy <- [
          "https://127.1",
          "https://001.002.003.004",
          "https://2130706433",
          "https://0x7f.0.0.1",
          "https://0177.0.0.1"
        ] do
      Application.put_env(:demo_app, Endpoint, check_origin: [legacy_policy])
      assert_error(Config.normalize(:demo_app, web_build(), ipv4_dev), :config_invalid)
    end

    for invalid_policy <- [
          "https://user@[::1]",
          "https://[:::1]",
          "https://[::1]:0",
          "https://[::1]//",
          "//*.example.com/socket"
        ] do
      Application.put_env(:demo_app, Endpoint, check_origin: [invalid_policy])
      assert_error(Config.normalize(:demo_app, web_build(), dev), :config_invalid)
    end
  end

  defp web_build do
    [
      schema: 1,
      client: "lib",
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
      public: "test",
      hot_styles: ["styles/app.css"],
      projection: [mode: :phoenix_static, root: "priv/static/rekindle"]
    ]
  end

  defp desktop_build do
    [
      schema: 1,
      client: "lib",
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

  defp put_web_target(build, function) do
    Keyword.update!(build, :targets, &Keyword.update!(&1, :web, function))
  end

  defp put_desktop_target(build, function) do
    Keyword.update!(build, :targets, &Keyword.update!(&1, :desktop, function))
  end

  defp put_web_features(features) do
    put_web_target(web_build(), &Keyword.put(&1, :features, features))
  end

  defp resource_config(:cache, field, value) do
    build = Keyword.update!(web_build(), :cache, &Keyword.put(&1, field, value))
    {build, web_dev()}
  end

  defp resource_config(:process, field, value) do
    build = Keyword.update!(web_build(), :process, &Keyword.put(&1, field, value))
    {build, web_dev()}
  end

  defp resource_config(:runtime, :startup_grace_ms, value) do
    runtime = [readiness: :startup_grace, handoff: :disabled, startup_grace_ms: value]
    build = put_desktop_target(desktop_build(), &Keyword.put(&1, :runtime, runtime))
    {build, []}
  end

  defp resource_config(:runtime, field, value) do
    build =
      put_desktop_target(desktop_build(), fn target ->
        Keyword.put(target, :runtime, [{field, value}])
      end)

    {build, []}
  end

  defp resource_config(:dev, field, value) do
    {web_build(), Keyword.put(web_dev(), field, value)}
  end

  defp resource_value(project, :cache, field), do: Map.fetch!(project.build.cache, field)
  defp resource_value(project, :process, field), do: Map.fetch!(project.build.process, field)

  defp resource_value(project, :runtime, field),
    do: Map.fetch!(project.build.targets.desktop.runtime, field)

  defp resource_value(project, :dev, field), do: Map.fetch!(project.dev, field)

  defp feature_vector(count, width) do
    for index <- 1..count do
      index
      |> Integer.to_string()
      |> String.pad_leading(3, "0")
      |> then(&("f" <> &1))
      |> String.pad_trailing(width, "x")
    end
  end

  defp web_dev do
    [schema: 1, enabled: true, targets: [:web], endpoint: Endpoint]
  end

  defp assert_error(result, code) do
    assert {:error, errors} = result
    assert Enum.any?(errors, &(&1.code == code)), "expected #{code}, got: #{inspect(errors)}"
  end
end
