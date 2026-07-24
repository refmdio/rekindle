defmodule Rekindle.DevelopmentTest do
  use ExUnit.Case, async: false

  alias Rekindle.Build.Result
  alias Rekindle.Development.Builder
  alias Rekindle.Desktop.Development, as: DesktopDevelopment
  alias Rekindle.Web.Development

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-development-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))
    File.write!(Path.join(root, "client/src/bin/web.rs"), "fn main() {}\n")
    File.write!(Path.join(root, "client/src/bin/desktop.rs"), "fn main() {}\n")

    Application.put_env(:rekindle_development_test, Rekindle,
      integration: :gpui,
      targets: [web: [], desktop: []]
    )

    on_exit(fn ->
      Application.delete_env(:rekindle_development_test, Rekindle)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "debounces changes and builds different targets concurrently", %{root: root} do
    test = self()

    build = fn target, _options ->
      send(test, {:started, target, self()})

      receive do
        :finish -> {:ok, result(root, target, Atom.to_string(target))}
      end
    end

    builder = start_builder(root, build)
    Builder.rebuild(builder, :web)
    Builder.rebuild(builder, :web)
    Builder.rebuild(builder, :all)

    assert_receive {:started, :web, web}
    assert_receive {:started, :desktop, desktop}
    refute web == desktop
    refute_receive {:started, _target, _pid}, 30

    send(web, :finish)
    send(desktop, :finish)

    assert_receive {Builder, :web, {:ok, %Result{target: :web}}}
    assert_receive {Builder, :desktop, {:ok, %Result{target: :desktop}}}
  end

  test "supersedes a running build and only reports the newest result", %{root: root} do
    test = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    build = fn target, options ->
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test, {:started, attempt, self()})

      if attempt == 1 do
        expected_cancel = options[:cancel_ref]

        receive do
          {:rekindle_cancel, ^expected_cancel} ->
            send(test, {:cancelled, attempt})
        after
          1_000 ->
            flunk("build was not cancelled")
        end
      else
        receive do
          :finish -> :ok
        end
      end

      {:ok, result(root, target, Integer.to_string(attempt))}
    end

    activate = fn result ->
      send(test, {:activated, result.metadata.generation})
      :ok
    end

    builder = start_builder(root, build, activate: activate)
    Builder.rebuild(builder, :web)
    assert_receive {:started, 1, _pid}

    Builder.rebuild(builder, :web)
    assert_receive {:cancelled, 1}
    assert_receive {:started, 2, second}
    refute_receive {:activated, "1"}, 30
    refute_receive {Builder, :web, _result}, 30

    send(second, :finish)

    assert_receive {:activated, "2"}
    assert_receive {Builder, :web, {:ok, %Result{metadata: %{generation: "2"}}}}
  end

  @tag capture_log: true
  test "removes a generation published by a superseded build", %{root: root} do
    test = self()
    selected = publish_web(root, "export default 'selected';")
    stale = String.duplicate("f", 64)
    stale_root = Path.join([root, ".rekindle", "dev", "web", stale])
    File.mkdir_p!(stale_root)
    manifest = Path.join(stale_root, "manifest.json")
    File.write!(manifest, "{}")
    counter = start_supervised!({Agent, fn -> 0 end})

    build = fn _target, options ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          send(test, :stale_started)
          cancel_ref = options[:cancel_ref]
          receive do: ({:rekindle_cancel, ^cancel_ref} -> :ok)

          {:ok,
           %Result{
             target: :web,
             profile: :dev,
             artifact: Path.join(stale_root, "app.js"),
             metadata: %{generation: stale, manifest: manifest}
           }}

        1 ->
          send(test, :current_started)
          {:error, :expected_test_stop}
      end
    end

    builder = start_builder(root, build)
    Builder.rebuild(builder, :web)
    assert_receive :stale_started
    Builder.rebuild(builder, :web)
    assert_receive :current_started

    refute File.exists?(stale_root)
    assert File.dir?(Path.join([root, ".rekindle", "dev", "web", selected]))
  end

  @tag capture_log: true
  test "retains the last successful result when a later build fails", %{root: root} do
    counter = start_supervised!({Agent, fn -> 0 end})

    build = fn target, _options ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:ok, result(root, target, "successful")}
        1 -> {:error, :compile_failed}
      end
    end

    builder = start_builder(root, build)
    Builder.rebuild(builder, :desktop)
    assert_receive {Builder, :desktop, {:ok, successful}}

    Builder.rebuild(builder, :desktop)
    assert_receive {Builder, :desktop, {:error, :compile_failed}}

    assert %{desktop: %{building?: false, last_success: ^successful, revision: 2}} =
             Builder.status(builder)
  end

  test "cancels a running build when its supervisor stops", %{root: root} do
    test = self()

    build = fn _target, options ->
      send(test, :build_started)
      expected_cancel = options[:cancel_ref]

      receive do
        {:rekindle_cancel, ^expected_cancel} -> send(test, :build_cancelled)
      end

      {:error, :cancelled}
    end

    builder = start_builder(root, build)
    Builder.rebuild(builder, :web)
    assert_receive :build_started

    stop_supervised(Builder)
    assert_receive :build_cancelled
    refute Process.alive?(builder)
  end

  @tag capture_log: true
  test "reports a Web build failure and clears it after recovery", %{root: root} do
    publish_web(root, "export default 'previous';")
    counter = start_supervised!({Agent, fn -> 0 end})

    build = fn target, _options ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:error, :compile_failed}
        1 -> {:ok, result(root, target, "recovered")}
      end
    end

    builder = start_builder(root, build)
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)

    Builder.rebuild(builder, :web)
    assert_receive {Builder, :web, {:error, :compile_failed}}
    assert request("/__rekindle/current", options).status == 409

    Builder.rebuild(builder, :web)
    assert_receive {Builder, :web, {:ok, %Result{}}}
    assert request("/__rekindle/current", options).status == 200
  end

  test "serves the current generation and checks GPUI capability before import", %{root: root} do
    generation = publish_web(root, "export default 'ready';")
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)

    current = request("/__rekindle/current", options)
    assert current.status == 200
    assert get_resp_header(current, "cache-control") == ["no-store"]

    assert Jason.decode!(current.resp_body) == %{
             "generation" => generation,
             "entry" => "/__rekindle/web/#{generation}/app.js"
           }

    asset = request("/__rekindle/web/#{generation}/app.js", options)
    assert asset.status == 200
    assert asset.resp_body == "export default 'ready';"
    assert get_resp_header(asset, "cache-control") == ["public, max-age=31536000, immutable"]

    runtime = request("/__rekindle/runtime.js", options)
    assert runtime.status == 200
    assert runtime.resp_body =~ "navigator.gpu"
    assert runtime.resp_body =~ "await graphicsReady();"
    assert runtime.resp_body =~ "const module = await import(current.entry);"
    assert runtime.resp_body =~ "await module.default();"
    refute runtime.resp_body =~ ~s|getContext("webgl2")|

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert :ok = Development.put_error(project, "Rust compilation failed")
    failure = request("/__rekindle/current", options)
    assert failure.status == 409
    assert Jason.decode!(failure.resp_body) == %{"error" => "Rust compilation failed"}

    assert :ok = Development.clear_error(project)
    assert request("/__rekindle/current", options).status == 200
  end

  test "uses WebGL2 diagnostics for egui without requiring WebGPU", %{root: root} do
    Application.put_env(:rekindle_development_test, Rekindle,
      integration: :egui,
      targets: [web: []]
    )

    options = Development.init(otp_app: :rekindle_development_test, project_root: root)
    page = request("/__rekindle", options)
    runtime = request("/__rekindle/runtime.js", options)

    assert page.status == 200
    assert page.resp_body =~ ~s(<canvas id="rekindle-canvas"></canvas>)
    assert runtime.resp_body =~ ~s|getContext("webgl2")|
    refute runtime.resp_body =~ "navigator.gpu"
  end

  @tag timeout: 60_000
  test "initializes Web output and reloads a changed generation in Chromium", %{root: root} do
    browser = System.find_executable("chromium") || flunk("Chromium is required")
    host_root = Path.join(root, "browser-runtime")
    profile = Path.join(root, "chromium-profile")
    first = String.duplicate("a", 64)
    second = String.duplicate("b", 64)
    File.mkdir_p!(Path.join(host_root, "__rekindle/web/#{first}"))
    File.mkdir_p!(Path.join(host_root, "__rekindle/web/#{second}"))

    Application.put_env(:rekindle_development_test, Rekindle,
      integration: :egui,
      targets: [web: []]
    )

    options = Development.init(otp_app: :rekindle_development_test, project_root: root)
    page = request("/__rekindle", options).resp_body
    runtime = request("/__rekindle/runtime.js", options).resp_body

    selector_override =
      """
      <script>
        HTMLCanvasElement.prototype.getContext = () => ({});
        const fetchFromServer = window.fetch.bind(window);
        window.fetch = (input, options) => {
          const url = new URL(input, window.location.href);
          if (url.pathname === "/__rekindle/current") {
            const polls = Number(sessionStorage.getItem("rekindle-polls") || "0") + 1;
            sessionStorage.setItem("rekindle-polls", String(polls));
            const generation = polls === 1 ? "#{first}" : "#{second}";
            return Promise.resolve(new Response(JSON.stringify({
              generation,
              entry: `/__rekindle/web/${generation}/app.js`
            }), {status: 200, headers: {"content-type": "application/json"}}));
          }
          return fetchFromServer(input, options);
        };
      </script>
      """

    page =
      String.replace(
        page,
        ~s(<script type="module" src="/__rekindle/runtime.js"></script>),
        selector_override <> ~s(<script type="module" src="/__rekindle/runtime.js"></script>)
      )

    File.write!(Path.join(host_root, "index.html"), page)
    File.mkdir_p!(Path.join(host_root, "__rekindle"))
    File.write!(Path.join(host_root, "__rekindle/runtime.js"), runtime)
    File.write!(Path.join(host_root, "__rekindle/web/#{first}/app.js"), browser_module(first))
    File.write!(Path.join(host_root, "__rekindle/web/#{second}/app.js"), browser_module(second))

    {:ok, server} =
      :inets.start(:httpd,
        bind_address: ~c"127.0.0.1",
        port: 0,
        server_name: ~c"rekindle-development-test",
        server_root: String.to_charlist(host_root),
        document_root: String.to_charlist(host_root),
        modules: [:mod_alias, :mod_dir, :mod_get, :mod_head],
        directory_index: [~c"index.html"],
        mime_types: [
          {~c"html", ~c"text/html"},
          {~c"js", ~c"text/javascript"}
        ]
      )

    port = :httpd.info(server) |> Keyword.fetch!(:port)

    try do
      arguments = [
        "--headless=new",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-dev-shm-usage",
        "--user-data-dir=#{profile}",
        "--virtual-time-budget=3000",
        "--dump-dom",
        "http://127.0.0.1:#{port}/"
      ]

      assert {:ok, %{status: 0, output: output}} =
               Rekindle.Toolchain.Process.run(browser, arguments,
                 cd: host_root,
                 timeout: 30_000,
                 output_limit: 1_000_000
               )

      assert output =~ ~s(data-rekindle-status="ready")
      assert output =~ ~s(data-rekindle-generation="#{second}")
      assert output =~ ~s(data-rekindle-loads="2")
    after
      :inets.stop(:httpd, server)
    end
  end

  @tag timeout: 60_000
  test "rejects missing browser graphics capabilities before importing Web output", %{root: root} do
    cases = [
      {:gpui,
       "Object.defineProperty(navigator, 'gpu', {value: {requestAdapter: async () => ({})}});",
       &String.replace(&1, "window.isSecureContext", "false"),
       "WebGPU requires HTTPS or a loopback origin."},
      {:gpui,
       "Object.defineProperty(navigator, 'gpu', {value: {requestAdapter: async () => null}});",
       &String.replace(&1, "window.isSecureContext", "true"),
       "No WebGPU graphics adapter is available."},
      {:egui, "HTMLCanvasElement.prototype.getContext = () => null;", & &1,
       "No WebGL2 graphics context is available."},
      {:slint, "HTMLCanvasElement.prototype.getContext = () => null;", & &1,
       "No WebGL2 graphics context is available."}
    ]

    Enum.each(cases, fn {integration, setup, transform, expected} ->
      output = run_browser_failure(root, integration, setup, transform)
      assert output =~ ~s(data-rekindle-runtime="executed")
      assert output =~ ~s(<pre id="rekindle-error">#{expected}</pre>)
      refute output =~ "data-rekindle-imported"
    end)
  end

  test "does not expose unselected or malformed Web paths", %{root: root} do
    generation = publish_web(root, "export default 'ready';")
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)

    assert request("/__rekindle/web/#{generation}/missing.js", options).status == 404
    assert request("/__rekindle/web/not-a-generation/app.js", options).status == 404

    conn = Plug.Test.conn("GET", "/unrelated") |> Development.call(options)
    refute conn.halted
    refute conn.state == :sent
  end

  test "stops the running desktop process before starting its replacement", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    first = desktop_result(root, "first", :running)
    second = desktop_result(root, "second", :running)

    DesktopDevelopment.replace(launcher, first)
    assert_receive {DesktopDevelopment, {:ready, ^first}}, 1_000

    assert %{current: %{pid: first_pid}, candidate: nil} =
             DesktopDevelopment.status(launcher)

    assert Process.alive?(first_pid)
    assert read_marker(root)["generation"] == first.metadata.generation

    DesktopDevelopment.replace(launcher, second)
    assert_until(fn -> DesktopDevelopment.status(launcher).candidate != nil end)
    refute Process.alive?(first_pid)
    assert read_marker(root)["generation"] == first.metadata.generation

    assert_receive {DesktopDevelopment, {:ready, ^second}}, 1_000
    refute Process.alive?(first_pid)
    assert read_marker(root)["generation"] == second.metadata.generation
  end

  @tag capture_log: true
  test "keeps the running desktop process when its replacement exits early", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    first = desktop_result(root, "stable", :running)
    broken = desktop_result(root, "broken", :exit)

    DesktopDevelopment.replace(launcher, first)
    assert_receive {DesktopDevelopment, {:ready, ^first}}, 1_000
    %{current: %{pid: first_pid}} = DesktopDevelopment.status(launcher)

    DesktopDevelopment.replace(launcher, broken)

    assert_receive {DesktopDevelopment, {:error, %Rekindle.Desktop.Error{kind: :readiness}}},
                   1_000

    assert_receive {DesktopDevelopment, {:ready, ^first}}, 1_000

    assert %{current: %{pid: rollback_pid}, candidate: nil} =
             DesktopDevelopment.status(launcher)

    refute rollback_pid == first_pid
    refute Process.alive?(first_pid)
    assert Process.alive?(rollback_pid)
    assert Process.alive?(launcher)
    assert read_marker(root)["generation"] == first.metadata.generation
  end

  test "logs desktop failures without a notification process", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        launcher =
          start_supervised!(
            {DesktopDevelopment,
             project_root: root, supervisor: supervisor, readiness: 75, notify: nil}
          )

        broken = desktop_result(root, "unobserved", :exit)
        DesktopDevelopment.replace(launcher, broken)

        assert_until(fn ->
          DesktopDevelopment.status(launcher) == %{current: nil, candidate: nil}
        end)
      end)

    assert log =~ "desktop development failed"
    assert log =~ "exited before it became ready"
  end

  @tag capture_log: true
  test "bounds failed desktop generations while preserving the running build", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    stable = desktop_result(root, "retained", :running)

    DesktopDevelopment.replace(launcher, stable)
    assert_receive {DesktopDevelopment, {:ready, ^stable}}, 1_000

    for name <- ~w(failed-one failed-two failed-three) do
      broken = desktop_result(root, name, :exit)
      DesktopDevelopment.replace(launcher, broken)

      assert_receive {DesktopDevelopment, {:error, %Rekindle.Desktop.Error{kind: :readiness}}},
                     1_000

      assert_receive {DesktopDevelopment, {:ready, ^stable}}, 1_000
    end

    generation_root = Path.join([root, ".rekindle", "dev", "desktop", "test-target"])
    generations = File.ls!(generation_root)

    assert length(generations) == 2
    assert stable.metadata.generation in generations
    assert Process.alive?(launcher)
  end

  @tag capture_log: true
  test "attempts the retained desktop executable only once", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    retained = desktop_result(root, "one-restart", :running_once)
    broken = desktop_result(root, "replacement", :exit)

    DesktopDevelopment.replace(launcher, retained)
    assert_receive {DesktopDevelopment, {:ready, ^retained}}, 1_000

    DesktopDevelopment.replace(launcher, broken)

    assert_receive {DesktopDevelopment, {:error, %Rekindle.Desktop.Error{kind: :readiness}}},
                   1_000

    assert_receive {DesktopDevelopment, {:error, %Rekindle.Desktop.Error{kind: :readiness}}},
                   1_000

    assert_until(fn ->
      DesktopDevelopment.status(launcher) == %{current: nil, candidate: nil}
    end)

    refute_receive {DesktopDevelopment, {:ready, ^retained}}, 200
    assert Process.alive?(launcher)
  end

  test "stops the desktop process with its owning supervisor", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    result = desktop_result(root, "shutdown", :running)

    DesktopDevelopment.replace(launcher, result)
    assert_receive {DesktopDevelopment, {:ready, ^result}}, 1_000
    %{current: %{pid: daemon}} = DesktopDevelopment.status(launcher)

    stop_supervised(DesktopDevelopment)
    assert_until(fn -> not Process.alive?(daemon) end)
  end

  test "maps client changes to affected targets and ignores Cargo output", %{root: root} do
    client = Path.join(root, "client")

    assert Rekindle.Development.Watcher.targets(client, Path.join(client, "src/lib.rs")) == [
             :web,
             :desktop
           ]

    assert Rekindle.Development.Watcher.targets(
             client,
             Path.join(client, "src/bin/web.rs")
           ) == [:web]

    assert Rekindle.Development.Watcher.targets(
             client,
             Path.join(client, "src/bin/desktop.rs")
           ) == [:desktop]

    assert Rekindle.Development.Watcher.targets(client, Path.join(client, "public/icon.svg")) == [
             :web
           ]

    assert Rekindle.Development.Watcher.targets(
             client,
             Path.join(client, "target/debug/client")
           ) == []

    custom_target = Path.join(client, ".cargo-output")

    assert Rekindle.Development.Watcher.targets(
             client,
             Path.join(custom_target, "debug/client"),
             custom_target
           ) == []

    assert Rekindle.Development.Watcher.targets(client, Path.join(root, "outside.rs")) == []
  end

  @tag capture_log: true
  test "rebuilds the affected target from an actual file-system event", %{root: root} do
    test = self()

    build = fn target, _options ->
      send(test, {:file_system_build, target})
      {:ok, result(root, target, "file-system-#{target}")}
    end

    builder = start_builder(root, build)

    source =
      start_supervised!(%{
        id: :development_file_system,
        start:
          {FileSystem, :start_link,
           [
             [
               backend: :fs_poll,
               dirs: [Path.join(root, "client")],
               interval: 20
             ]
           ]}
      })

    start_supervised!(
      {Rekindle.Development.Watcher,
       source: source, builder: builder, root: Path.join(root, "client")}
    )

    assert_receive {:file_system_build, :web}, 1_000
    assert_receive {:file_system_build, :desktop}, 1_000
    Process.sleep(50)

    File.mkdir_p!(Path.join(root, "client/public"))
    File.write!(Path.join(root, "client/public/icon.svg"), "<svg/>")

    assert_receive {:file_system_build, :web}, 1_000
    refute_receive {:file_system_build, :desktop}, 150
  end

  test "removes only superseded development generations", %{root: root} do
    web_root = Path.join([root, ".rekindle", "dev", "web"])
    release_root = Path.join([root, ".rekindle", "release", "web"])
    generations = Enum.map(1..3, &String.duplicate(Integer.to_string(&1), 64))

    Enum.with_index(generations, fn generation, index ->
      path = Path.join(web_root, generation)
      File.mkdir_p!(path)
      File.touch!(path, {{2026, 1, 1}, {0, 0, index}})
    end)

    File.mkdir_p!(Path.join(release_root, hd(generations)))
    File.write!(Path.join(web_root, "user-file"), "keep")

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert :ok = Rekindle.Development.Cleanup.web(project, List.last(generations))

    assert File.dir?(Path.join(web_root, List.last(generations)))
    assert length(Path.wildcard(Path.join(web_root, String.duplicate("?", 64)))) == 2
    assert File.regular?(Path.join(web_root, "user-file"))
    assert File.dir?(Path.join(release_root, hd(generations)))
  end

  test "cleans abandoned startup output while preserving selected generations", %{root: root} do
    temporary = Path.join([root, ".rekindle", "tmp", "web", "abandoned"])
    marker = Path.join([root, ".rekindle", "dev", "web-current.json.tmp-abandoned"])
    File.mkdir_p!(temporary)
    File.write!(Path.join(temporary, "partial"), "partial")
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, "partial")

    selected = publish_web(root, "export default 'selected';")
    web_root = Path.join([root, ".rekindle", "dev", "web"])

    for value <- ["c", "d", "e"] do
      generation = String.duplicate(value, 64)
      File.mkdir_p!(Path.join(web_root, generation))
      File.touch!(Path.join(web_root, generation))
    end

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert :ok = Rekindle.Development.Cleanup.startup(project)
    refute File.exists?(Path.join([root, ".rekindle", "tmp"]))
    refute File.exists?(marker)
    assert File.dir?(Path.join(web_root, selected))
    assert length(Path.wildcard(Path.join(web_root, String.duplicate("?", 64)))) == 2
  end

  defp start_builder(root, build, options \\ []) do
    start_supervised!(
      {Builder,
       Keyword.merge(
         [
           otp_app: :rekindle_development_test,
           project_root: root,
           debounce: 10,
           notify: self(),
           build: build,
           activate: fn _result -> :ok end
         ],
         options
       )}
    )
  end

  defp result(root, target, generation) do
    %Result{
      target: target,
      profile: :dev,
      artifact: Path.join(root, generation),
      metadata: %{generation: generation}
    }
  end

  defp publish_web(root, source) do
    temporary = Path.join(root, "web-source")
    File.mkdir_p!(temporary)
    File.write!(Path.join(temporary, "app.js"), source)
    {:ok, manifest} = Rekindle.Web.Manifest.create(temporary, "app.js")
    generation = manifest["generation"]
    generation_root = Path.join([root, ".rekindle", "dev", "web", generation])
    File.mkdir_p!(generation_root)
    File.cp!(Path.join(temporary, "app.js"), Path.join(generation_root, "app.js"))
    File.write!(Path.join(generation_root, "manifest.json"), Jason.encode!(manifest))

    File.write!(
      Path.join(root, ".rekindle/dev/web-current.json"),
      Jason.encode!(%{"generation" => generation})
    )

    generation
  end

  defp request(path, options) do
    Plug.Test.conn("GET", path)
    |> Development.call(options)
  end

  defp get_resp_header(conn, name), do: Plug.Conn.get_resp_header(conn, name)

  defp browser_module(generation) do
    """
    export default async function initialize() {
      const loads = Number(sessionStorage.getItem("rekindle-loads") || "0") + 1;
      sessionStorage.setItem("rekindle-loads", String(loads));
      document.documentElement.dataset.rekindleStatus = "ready";
      document.documentElement.dataset.rekindleGeneration = "#{generation}";
      document.documentElement.dataset.rekindleLoads = String(loads);
    }
    """
  end

  defp run_browser_failure(root, integration, setup, transform) do
    browser = System.find_executable("chromium") || flunk("Chromium is required")

    Application.put_env(:rekindle_development_test, Rekindle,
      integration: integration,
      targets: [web: []]
    )

    options = Development.init(otp_app: :rekindle_development_test, project_root: root)

    runtime =
      options
      |> then(&request("/__rekindle/runtime.js", &1).resp_body)
      |> transform.()
      |> then(&("document.documentElement.dataset.rekindleRuntime = \"executed\";\n" <> &1))
      |> String.replace(
        "const module = await import(current.entry);",
        """
        document.documentElement.dataset.rekindleImported = "true";
        const module = await import(current.entry);
        """
      )

    generation = String.duplicate("a", 64)

    selector =
      Jason.encode!(%{
        generation: generation,
        entry:
          "data:text/javascript,export default async function initialize() " <>
            "{ document.documentElement.dataset.applicationStarted = 'true'; }"
      })

    page =
      """
      <!doctype html>
      <html><body>
        <canvas id="rekindle-canvas"></canvas>
        <pre id="rekindle-error" hidden></pre>
        <script>
          #{setup}
          window.fetch = () => Promise.resolve(
            new Response(#{Jason.encode!(selector)}, {
              status: 200,
              headers: {"content-type": "application/json"}
            })
          );
        </script>
        <script type="module">#{runtime}</script>
      </body></html>
      """

    directory =
      Path.join(root, "browser-failure-#{integration}-#{System.unique_integer([:positive])}")

    profile = Path.join(directory, "profile")
    File.mkdir_p!(directory)
    page_path = Path.join(directory, "index.html")
    File.write!(page_path, page)

    arguments = [
      "--headless=new",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-dev-shm-usage",
      "--allow-file-access-from-files",
      "--user-data-dir=#{profile}",
      "--virtual-time-budget=1000",
      "--dump-dom",
      "file://#{page_path}"
    ]

    assert {:ok, %{status: 0, output: output}} =
             Rekindle.Toolchain.Process.run(browser, arguments,
               cd: directory,
               timeout: 15_000,
               output_limit: 1_000_000
             )

    output
  end

  defp start_launcher(root, supervisor) do
    start_supervised!(
      {DesktopDevelopment,
       project_root: root, supervisor: supervisor, readiness: 75, notify: self()}
    )
  end

  defp desktop_result(root, name, behavior) do
    source = Path.join(root, "#{name}.sh")

    body =
      case behavior do
        :running ->
          "#!/bin/sh\n# #{name}\nwhile true; do sleep 1; done\n"

        :exit ->
          "#!/bin/sh\n# #{name}\nexit 0\n"

        :running_once ->
          marker = source <> ".started"

          """
          #!/bin/sh
          if [ -f '#{marker}' ]; then exit 0; fi
          touch '#{marker}'
          while true; do sleep 1; done
          """
      end

    File.write!(source, body)
    File.chmod!(source, 0o755)
    target = "test-target"
    temporary = Path.join(root, "#{name}-generation")
    File.mkdir_p!(temporary)
    executable = "desktop"
    artifact = Path.join(temporary, executable)
    File.cp!(source, artifact)
    File.chmod!(artifact, 0o755)

    {:ok, manifest} =
      Rekindle.Desktop.Manifest.create(temporary, executable, target, "client", "desktop")

    generation_root =
      Path.join([root, ".rekindle", "dev", "desktop", target, manifest["generation"]])

    File.mkdir_p!(Path.dirname(generation_root))
    File.rename!(temporary, generation_root)
    manifest_path = Path.join(generation_root, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    %Result{
      target: :desktop,
      profile: :dev,
      artifact: Path.join(generation_root, executable),
      metadata: %{
        generation: manifest["generation"],
        manifest: manifest_path,
        rust_target: target
      }
    }
  end

  defp read_marker(root) do
    root
    |> Path.join(".rekindle/dev/desktop-last-running.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp assert_until(fun, attempts \\ 50)

  defp assert_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_until(fun, attempts - 1)
    end
  end

  defp assert_until(_fun, 0), do: flunk("condition did not become true")
end
