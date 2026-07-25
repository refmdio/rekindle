defmodule Rekindle.DevelopmentTest do
  use ExUnit.Case, async: false

  alias Rekindle.Build.Result
  alias Rekindle.Development.Builder
  alias Rekindle.Desktop.Development, as: DesktopDevelopment
  alias Rekindle.Phoenix.Development
  alias Rekindle.Test.IntegrationBrowser

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

  test "schedules all targets in canonical order regardless of configuration order", %{
    root: root
  } do
    Application.put_env(:rekindle_development_test, Rekindle,
      integration: :gpui,
      targets: [desktop: [], web: []]
    )

    test = self()

    build = fn target, _options ->
      send(test, {:started, target, self()})

      receive do
        :finish -> {:ok, result(root, target, Atom.to_string(target))}
      end
    end

    builder = start_builder(root, build)
    :erlang.trace(builder, true, [:receive])
    Builder.rebuild(builder, :all)

    assert_receive {:trace, ^builder, :receive, {:"$gen_cast", {:rebuild, :all}}}
    assert_receive {:trace, ^builder, :receive, {:build, :web, 1}}
    assert_receive {:trace, ^builder, :receive, {:build, :desktop, 1}}

    assert_receive {:started, :web, web}
    assert_receive {:started, :desktop, desktop}

    send(web, :finish)
    send(desktop, :finish)

    assert_receive {Builder, :web, {:ok, %Result{target: :web}}}
    assert_receive {Builder, :desktop, {:ok, %Result{target: :desktop}}}
  end

  test "schedules only configured targets when rebuilding all", %{root: root} do
    for target <- [:web, :desktop] do
      Application.put_env(:rekindle_development_test, Rekindle,
        integration: :gpui,
        targets: [{target, []}]
      )

      test = self()

      build = fn built_target, _options ->
        send(test, {:started, built_target})
        {:ok, result(root, built_target, Atom.to_string(built_target))}
      end

      builder = start_builder(root, build)
      Builder.rebuild(builder, :all)

      assert_receive {:started, ^target}
      assert_receive {Builder, ^target, {:ok, %Result{target: ^target}}}
      refute_receive {:started, _target}, 30

      stop_supervised(Builder)
    end
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

  test "serializes stale Web cleanup with activation across VMs", %{root: root} do
    selected = publish_web(root, "export default 'selected';")
    stale = publish_web(root, "export default 'stale';")
    select_web(root, selected)

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    stale_result = web_result(root, stale)
    ready = Path.join(root, "web-publication.ready")
    release = Path.join(root, "web-publication.release")
    port = publication_lock_process(root, {:web, :dev}, ready, release)

    on_exit(fn ->
      File.write(release, "release")
      if Port.info(port), do: Port.close(port)
    end)

    assert_until(fn -> File.regular?(ready) end, 200)

    cleanup =
      Task.async(fn -> Rekindle.Development.Cleanup.discard(project, stale_result) end)

    assert Task.yield(cleanup, 100) == nil
    assert File.dir?(Path.dirname(stale_result.metadata.manifest))
    assert selected_web(root) == selected

    File.write!(release, "release")
    assert_receive {^port, {:exit_status, 0}}, 5_000
    assert :ok = Task.await(cleanup, 5_000)
    refute File.exists?(Path.dirname(stale_result.metadata.manifest))
    assert selected_web(root) == selected
    assert_valid_web_generation(root, selected)

    activated = publish_web(root, "export default 'activated';")
    select_web(root, selected)
    activated_result = web_result(root, activated)

    assert :ok = Rekindle.Web.Builder.activate(project, activated_result)
    assert :ok = Rekindle.Development.Cleanup.discard(project, activated_result)
    assert selected_web(root) == activated
    assert_valid_web_generation(root, activated)

    discarded = publish_web(root, "export default 'discarded';")
    select_web(root, activated)
    discarded_result = web_result(root, discarded)

    assert :ok = Rekindle.Development.Cleanup.discard(project, discarded_result)

    assert {:error, %Rekindle.Web.Error{kind: :manifest_read}} =
             Rekindle.Web.Builder.activate(project, discarded_result)

    assert selected_web(root) == activated
    assert_valid_web_generation(root, activated)
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

  test "rejects linked and special Web runtime state without blocking requests", %{root: root} do
    generation = publish_web(root, "export default 'ready';")
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)
    selector = Path.join(root, ".rekindle/dev/web-current.json")
    error = Path.join(root, ".rekindle/dev/web-error.json")
    manifest = Path.join([root, ".rekindle", "dev", "web", generation, "manifest.json"])

    for kind <- [:symlink, :fifo] do
      with_special_file(selector, kind, Jason.encode!(%{"generation" => generation}), fn ->
        assert {:ok, %{status: 503}} =
                 bounded(fn -> request("/__rekindle/current", options) end)
      end)

      with_special_file(error, kind, Jason.encode!(%{"error" => "linked"}), fn ->
        assert {:ok, %{status: 200}} =
                 bounded(fn -> request("/__rekindle/current", options) end)
      end)

      with_special_file(manifest, kind, "{}", fn ->
        assert {:ok, %{status: 503}} =
                 bounded(fn -> request("/__rekindle/current", options) end)

        assert {:ok, %{status: 404}} =
                 bounded(fn ->
                   request("/__rekindle/web/#{generation}/app.js", options)
                 end)
      end)
    end
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
    assert page.resp_body =~ Rekindle.Phoenix.web_host(:egui)
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
        "--disable-gpu",
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
  test "serializes delayed browser runtime polls and retries", %{root: root} do
    browser = System.find_executable("chromium") || flunk("Chromium is required")
    directory = Path.join(root, "browser-single-flight")
    profile = Path.join(directory, "profile")
    generation = String.duplicate("a", 64)

    Application.put_env(:rekindle_development_test, Rekindle,
      integration: :egui,
      targets: [web: []]
    )

    options = Development.init(otp_app: :rekindle_development_test, project_root: root)
    runtime = request("/__rekindle/runtime.js", options).resp_body

    module =
      """
      export default async function initialize() {
        const root = document.documentElement;
        const initializers = Number(root.dataset.initializers || "0") + 1;
        root.dataset.initializers = String(initializers);
        if (!root.dataset.requestsAtInitialization) {
          root.dataset.requestsAtInitialization = root.dataset.requests;
        }
      }
      """

    selector =
      Jason.encode!(%{
        generation: generation,
        entry: "data:text/javascript,#{URI.encode(module)}"
      })

    page =
      """
      <!doctype html>
      <html><body>
        <canvas id="the_canvas_id"></canvas>
        <pre id="rekindle-error" hidden></pre>
      <script>
        HTMLCanvasElement.prototype.getContext = () => ({});
        let requests = 0;
        window.fetch = () => {
          requests += 1;
          const request = requests;
          document.documentElement.dataset.requests = String(requests);
          return new Promise((resolve) => {
            window.setTimeout(() => {
              resolve(new Response(request === 1 ? "" : #{Jason.encode!(selector)}, {
                status: request === 1 ? 503 : 200,
                headers: {"content-type": "application/json"}
              }));
            }, 600);
          });
        };
      </script>
      <script type="module">#{runtime}</script>
      </body></html>
      """

    File.mkdir_p!(directory)
    page_path = Path.join(directory, "index.html")
    File.write!(page_path, page)

    arguments = [
      "--headless=new",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--allow-file-access-from-files",
      "--user-data-dir=#{profile}",
      "--virtual-time-budget=2500",
      "--dump-dom",
      "file://#{page_path}"
    ]

    assert {:ok, %{status: 0, output: output}} =
             Rekindle.Toolchain.Process.run(browser, arguments,
               cd: directory,
               timeout: 30_000,
               output_limit: 1_000_000
             )

    assert output =~ ~s(data-requests-at-initialization="2")
    assert output =~ ~s(data-initializers="1")
  end

  @tag timeout: 60_000
  test "rejects missing browser graphics capabilities before importing Web output", %{root: root} do
    cases = [
      {:gpui,
       "Object.defineProperty(navigator, 'gpu', {value: {requestAdapter: async () => ({})}});",
       &String.replace(&1, "window.isSecureContext", "false"),
       "WebGPU requires HTTPS or a loopback origin."},
      {:gpui, "Object.defineProperty(navigator, 'gpu', {value: undefined});",
       &String.replace(&1, "window.isSecureContext", "true"),
       "This browser does not expose WebGPU."},
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

  @tag timeout: 60_000
  test "starts each browser integration once when its graphics capability is available", %{
    root: root
  } do
    cases = [
      {:gpui,
       "Object.defineProperty(navigator, 'gpu', {value: {requestAdapter: async () => ({})}});",
       &String.replace(&1, "window.isSecureContext", "true")},
      {:egui, "HTMLCanvasElement.prototype.getContext = () => ({});", & &1},
      {:slint, "HTMLCanvasElement.prototype.getContext = () => ({});", & &1}
    ]

    module =
      """
      export default async function initialize() {
        const root = document.documentElement;
        const initializers = Number(root.dataset.initializers || "0") + 1;
        root.dataset.initializers = String(initializers);
        root.dataset.applicationStarted = "true";
      }
      """

    Enum.each(cases, fn {integration, setup, transform} ->
      selector = browser_selector(String.duplicate("a", 64), module)
      output = run_browser_responses(root, integration, setup, transform, [selector])

      assert output =~ ~s(data-application-started="true")
      assert output =~ ~s(data-initializers="1")
      refute output =~ "data-rekindle-error-count"
    end)
  end

  @tag timeout: 60_000
  test "reports browser startup failures and recovers on a later selection", %{root: root} do
    success =
      browser_selector(
        String.duplicate("b", 64),
        """
        export default async function initialize() {
          const root = document.documentElement;
          const initializers = Number(root.dataset.initializers || "0") + 1;
          root.dataset.initializers = String(initializers);
          root.dataset.applicationStarted = "true";
        }
        """
      )

    cases = [
      {"malformed", ["{", success], "SyntaxError"},
      {"missing-initializer",
       [
         browser_selector(String.duplicate("a", 64), "export const value = 1;"),
         success
       ], "does not export a wasm-bindgen initializer"},
      {"throwing-initializer",
       [
         browser_selector(
           String.duplicate("a", 64),
           """
           export default async function initialize() {
             document.documentElement.dataset.failedInitializerCalled = "true";
             throw new Error("initializer exploded");
           }
           """
         ),
         success
       ], "initializer exploded"}
    ]

    Enum.each(cases, fn {_name, responses, expected_error} ->
      output =
        run_browser_responses(
          root,
          :egui,
          "HTMLCanvasElement.prototype.getContext = () => ({});",
          & &1,
          responses
        )

      assert output =~ ~s(data-application-started="true")
      assert output =~ ~s(data-initializers="1")
      assert output =~ ~s(data-rekindle-error-count="1")
      assert output =~ expected_error
    end)
  end

  @tag timeout: 60_000
  test "serializes polls and recovers after a rejected selection request", %{root: root} do
    selector =
      browser_selector(
        String.duplicate("a", 64),
        """
        export default async function initialize() {
          const root = document.documentElement;
          root.dataset.initializers =
            String(Number(root.dataset.initializers || "0") + 1);
          root.dataset.requestsAtInitialization = root.dataset.requests;
          root.dataset.applicationStarted = "true";
        }
        """
      )

    output =
      run_browser_responses(
        root,
        :egui,
        "HTMLCanvasElement.prototype.getContext = () => ({});",
        & &1,
        [%{"reject" => "selection transport disconnected", "delay" => 600}, selector]
      )

    assert output =~ ~s(data-application-started="true")
    assert output =~ ~s(data-initializers="1")
    assert output =~ ~s(data-requests-at-initialization="2")
    assert output =~ ~s(data-rekindle-error-count="1")
    assert output =~ "TypeError: selection transport disconnected"
  end

  @tag timeout: 60_000
  test "recovers after the development endpoint disconnects and restarts", %{root: root} do
    browser = System.find_executable("chromium") || flunk("Chromium is required")
    driver = System.find_executable("chromedriver") || flunk("ChromeDriver is required")
    host_root = Path.join(root, "browser-endpoint-recovery")
    profile = Path.join(host_root, "profile")
    generation = String.duplicate("a", 64)
    File.mkdir_p!(Path.join(host_root, "__rekindle"))

    Application.put_env(:rekindle_development_test, Rekindle,
      integration: :egui,
      targets: [web: []]
    )

    options = Development.init(otp_app: :rekindle_development_test, project_root: root)
    runtime = request("/__rekindle/runtime.js", options).resp_body

    observer =
      """
      <script>
        HTMLCanvasElement.prototype.getContext = () => ({});
        const originalConsoleError = console.error.bind(console);
        console.error = (...values) => {
          const error = values.find((value) => value instanceof Error);
          const message = error ? `${error.name}: ${error.message}` : values.join(" ");
          const root = document.documentElement;
          root.dataset.rekindleErrorCount =
            String(Number(root.dataset.rekindleErrorCount || "0") + 1);
          root.dataset.rekindleErrors =
            [root.dataset.rekindleErrors, message].filter(Boolean).join(" | ");
          originalConsoleError(...values);
        };
      </script>
      """

    page =
      options
      |> then(&request("/__rekindle", &1).resp_body)
      |> String.replace(
        ~s(<script type="module" src="/__rekindle/runtime.js"></script>),
        observer <> ~s(<script type="module" src="/__rekindle/runtime.js"></script>)
      )

    module =
      """
      export default async function initialize() {
        const root = document.documentElement;
        root.dataset.initializers =
          String(Number(root.dataset.initializers || "0") + 1);
        root.dataset.applicationStarted = "true";
      }
      """

    selector =
      browser_selector(generation, module)

    File.write!(Path.join(host_root, "index.html"), page)
    File.write!(Path.join(host_root, "__rekindle/runtime.js"), runtime)

    {:ok, server} = start_development_httpd(host_root, 0)
    port = :httpd.info(server) |> Keyword.fetch!(:port)

    try do
      IntegrationBrowser.with_webdriver!(
        driver,
        browser,
        profile,
        :webgl2,
        fn webdriver_port, session ->
          IntegrationBrowser.webdriver_request!(
            :post,
            webdriver_port,
            "/session/#{session}/url",
            %{"url" => "http://127.0.0.1:#{port}/"}
          )

          Process.sleep(300)
          assert :ok = :inets.stop(:httpd, server)
          Process.sleep(600)

          disconnected =
            development_browser_state(webdriver_port, session)

          assert disconnected["applicationStarted"] == nil
          assert disconnected["errorCount"] >= 1
          assert disconnected["errors"] =~ "TypeError"

          File.write!(Path.join(host_root, "__rekindle/current"), selector)
          {:ok, restarted} = start_development_httpd(host_root, port)

          try do
            assert_until(
              fn ->
                development_browser_state(webdriver_port, session)["applicationStarted"] == "true"
              end,
              1_000
            )

            recovered = development_browser_state(webdriver_port, session)
            assert recovered["initializers"] == "1"
            assert recovered["errorCount"] >= 1
            assert recovered["errors"] =~ "TypeError"

            Process.sleep(500)
            assert development_browser_state(webdriver_port, session)["initializers"] == "1"
          after
            :inets.stop(:httpd, restarted)
          end
        end
      )
    after
      :inets.stop(:httpd, server)
    end
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

  test "does not serve a changed or linked Web generation member", %{root: root} do
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)

    changed = publish_web(root, "export default 'unchanged';")
    changed_path = Path.join([root, ".rekindle", "dev", "web", changed, "app.js"])
    File.write!(changed_path, "changed bytes")

    response = request("/__rekindle/web/#{changed}/app.js", options)
    assert response.status == 404
    refute response.resp_body =~ "changed bytes"

    linked = publish_web(root, "export default 'linked';")
    linked_path = Path.join([root, ".rekindle", "dev", "web", linked, "app.js"])
    external = external_path(root, "member")
    File.write!(external, "external member secret")
    on_exit(fn -> File.rm_rf!(external) end)

    File.rm!(linked_path)
    File.ln_s!(external, linked_path)

    response = request("/__rekindle/web/#{linked}/app.js", options)
    assert response.status == 404
    refute response.resp_body =~ "external member secret"
  end

  test "serves the validated Web member when its path changes before sending", %{root: root} do
    source = "export default 'validated';"
    generation = publish_web(root, source)
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)
    member = Path.join([root, ".rekindle", "dev", "web", generation, "app.js"])
    external = external_path(root, "response-boundary")
    File.write!(external, "external response secret")
    on_exit(fn -> File.rm_rf!(external) end)

    response =
      Plug.Test.conn("GET", "/__rekindle/web/#{generation}/app.js")
      |> Plug.Conn.register_before_send(fn conn ->
        File.rm!(member)
        File.ln_s!(external, member)
        conn
      end)
      |> Development.call(options)

    assert response.status == 200
    assert response.resp_body == source
    refute response.resp_body =~ "external response secret"
  end

  test "does not serve a Web generation member through a linked ancestor", %{root: root} do
    generation =
      publish_web_members(root, %{
        "app.js" => "import './snippets/helper.js';",
        "snippets/helper.js" => "export const helper = 'ready';"
      })

    options = Development.init(otp_app: :rekindle_development_test, project_root: root)
    member_path = "/__rekindle/web/#{generation}/snippets/helper.js"

    valid = request(member_path, options)
    assert valid.status == 200
    assert valid.resp_body == "export const helper = 'ready';"

    snippets = Path.join([root, ".rekindle", "dev", "web", generation, "snippets"])
    external = external_path(root, "snippets")
    File.mkdir_p!(external)
    File.write!(Path.join(external, "helper.js"), "external ancestor secret")
    on_exit(fn -> File.rm_rf!(external) end)

    File.rm_rf!(snippets)
    File.ln_s!(external, snippets)

    response = request(member_path, options)
    assert response.status == 404
    refute response.resp_body =~ "external ancestor secret"
  end

  test "does not serve a Web generation through a linked generation root", %{root: root} do
    generation = publish_web(root, "export default 'generation root';")
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)
    generation_root = Path.join([root, ".rekindle", "dev", "web", generation])
    external = external_path(root, "generation")
    File.rename!(generation_root, external)
    File.ln_s!(external, generation_root)
    on_exit(fn -> File.rm_rf!(external) end)

    response = request("/__rekindle/web/#{generation}/app.js", options)
    assert response.status == 404
    refute response.resp_body =~ "generation root"
  end

  test "does not serve a Web generation through a linked state ancestor", %{root: root} do
    generation = publish_web(root, "export default 'state ancestor';")
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)
    web_root = Path.join([root, ".rekindle", "dev", "web"])
    external = external_path(root, "state")
    File.rename!(web_root, external)
    File.ln_s!(external, web_root)
    on_exit(fn -> File.rm_rf!(external) end)

    response = request("/__rekindle/web/#{generation}/app.js", options)
    assert response.status == 404
    refute response.resp_body =~ "state ancestor"
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
  test "keeps the running desktop process when replacement inventory is invalid", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    stable = desktop_result(root, "stable-inventory", :running)
    invalid = desktop_result(root, "invalid-inventory", :running)

    DesktopDevelopment.replace(launcher, stable)
    assert_receive {DesktopDevelopment, {:ready, ^stable}}, 1_000
    %{current: %{pid: stable_pid}} = DesktopDevelopment.status(launcher)

    File.ln_s!(invalid.artifact, Path.join(Path.dirname(invalid.artifact), "extra-link"))
    DesktopDevelopment.replace(launcher, invalid)

    assert_receive {DesktopDevelopment,
                    {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}}},
                   1_000

    assert %{current: %{pid: ^stable_pid}, candidate: nil} =
             DesktopDevelopment.status(launcher)

    assert Process.alive?(stable_pid)
    assert read_marker(root)["generation"] == stable.metadata.generation
  end

  @tag capture_log: true
  test "rejects linked and special desktop runtime state without blocking", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    stable = desktop_result(root, "stable-special-state", :running)

    DesktopDevelopment.replace(launcher, stable)
    assert_receive {DesktopDevelopment, {:ready, ^stable}}, 1_000
    %{current: %{pid: stable_pid}} = DesktopDevelopment.status(launcher)

    for kind <- [:symlink, :fifo] do
      candidate = desktop_result(root, "candidate-#{kind}", :running)

      with_special_file(candidate.metadata.manifest, kind, "{}", fn ->
        DesktopDevelopment.replace(launcher, candidate)

        assert_receive {DesktopDevelopment,
                        {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}}},
                       1_000

        assert %{current: %{pid: ^stable_pid}, candidate: nil} =
                 DesktopDevelopment.status(launcher)
      end)
    end

    stop_supervised(DesktopDevelopment)
    marker = Path.join(root, ".rekindle/dev/desktop-last-running.json")

    for kind <- [:symlink, :fifo] do
      with_special_file(marker, kind, "{}", fn ->
        assert {:ok, {:ok, restarted}} =
                 bounded(fn ->
                   GenServer.start(
                     DesktopDevelopment,
                     project_root: root,
                     supervisor: supervisor,
                     readiness: 75,
                     notify: nil
                   )
                 end)

        assert DesktopDevelopment.status(restarted) == %{current: nil, candidate: nil}
        GenServer.stop(restarted)
      end)
    end
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

  @tag capture_log: true
  test "clears a ready desktop process after it exits and preserves its marker", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    result = desktop_result(root, "current-crash", :running)

    DesktopDevelopment.replace(launcher, result)
    assert_receive {DesktopDevelopment, {:ready, ^result}}, 1_000

    assert %{current: %{pid: daemon}, candidate: nil} =
             DesktopDevelopment.status(launcher)

    Process.exit(daemon, :kill)

    assert_receive {DesktopDevelopment, {:exited, ^result, :killed}}, 1_000
    assert_until(fn -> not Process.alive?(daemon) end)
    assert DesktopDevelopment.status(launcher) == %{current: nil, candidate: nil}
    assert read_marker(root)["generation"] == result.metadata.generation
    refute_receive {DesktopDevelopment, {:exited, ^result, _reason}}, 100
    assert Process.alive?(launcher)
  end

  @tag capture_log: true
  test "leaves no desktop state when the first process exits before readiness", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    broken = desktop_result(root, "first-launch-failure", :exit)
    marker = Path.join(root, ".rekindle/dev/desktop-last-running.json")

    DesktopDevelopment.replace(launcher, broken)

    assert_receive {DesktopDevelopment, {:error, %Rekindle.Desktop.Error{kind: :readiness}}},
                   1_000

    assert_until(fn ->
      DesktopDevelopment.status(launcher) == %{current: nil, candidate: nil}
    end)

    assert DynamicSupervisor.which_children(supervisor) == []
    refute File.exists?(marker)
    refute_receive {DesktopDevelopment, {:ready, _result}}, 100
    refute_receive {DesktopDevelopment, {:exited, _result, _reason}}, 100
    refute_receive {DesktopDevelopment, {:error, _error}}, 100
    assert Process.alive?(launcher)
  end

  @tag capture_log: true
  test "restores the retained desktop process after the launcher restarts", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    retained = desktop_result(root, "persisted", :running)
    broken = desktop_result(root, "broken-after-restart", :exit)

    DesktopDevelopment.replace(launcher, retained)
    assert_receive {DesktopDevelopment, {:ready, ^retained}}, 1_000
    %{current: %{pid: original_pid}} = DesktopDevelopment.status(launcher)

    stop_supervised(DesktopDevelopment)
    assert_until(fn -> not Process.alive?(original_pid) end)

    restarted = start_launcher(root, supervisor)
    DesktopDevelopment.replace(restarted, broken)

    assert_receive {DesktopDevelopment, {:error, %Rekindle.Desktop.Error{kind: :readiness}}},
                   1_000

    assert_receive {DesktopDevelopment, {:ready, ^retained}}, 1_000

    assert %{current: %{pid: fallback_pid}, candidate: nil} =
             DesktopDevelopment.status(restarted)

    assert Process.alive?(fallback_pid)
    assert read_marker(root)["generation"] == retained.metadata.generation
  end

  @tag capture_log: true
  test "does not follow an invalid retained desktop manifest path", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    retained = desktop_result(root, "outside-marker", :running)
    broken = desktop_result(root, "invalid-marker-replacement", :exit)
    marker = Path.join(root, ".rekindle/dev/desktop-last-running.json")
    File.mkdir_p!(Path.dirname(marker))

    File.write!(
      marker,
      Jason.encode!(%{
        "generation" => retained.metadata.generation,
        "target" => retained.metadata.rust_target,
        "manifest" => Path.relative_to(retained.metadata.manifest, Path.dirname(root))
      })
    )

    launcher = start_launcher(root, supervisor)
    DesktopDevelopment.replace(launcher, broken)

    assert_receive {DesktopDevelopment, {:error, %Rekindle.Desktop.Error{kind: :readiness}}},
                   1_000

    assert_until(fn ->
      DesktopDevelopment.status(launcher) == %{current: nil, candidate: nil}
    end)

    refute_receive {DesktopDevelopment, {:ready, ^retained}}, 200
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

    generation_root =
      Path.join([
        root,
        ".rekindle",
        "dev",
        "desktop",
        Rekindle.Toolchain.desktop_target()
      ])

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

  test "serializes desktop selection and cleanup with independent VMs", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    selected = desktop_result(root, "selected-after-lock", :running)
    stale = desktop_result(root, "cleanup-after-lock", :exit)
    ready = Path.join(root, "desktop-development.ready")
    release = Path.join(root, "desktop-development.release")
    port = publication_lock_process(root, {:desktop, :dev}, ready, release)

    on_exit(fn ->
      File.write(release, "release")
      if Port.info(port), do: Port.close(port)
    end)

    assert_until(fn -> File.regular?(ready) end, 200)

    assert :independent =
             Rekindle.Publication.with_lock(
               root,
               {:web, :dev},
               fn -> :independent end,
               50
             )

    DesktopDevelopment.replace(launcher, selected)
    cleanup = Task.async(fn -> Rekindle.Development.Cleanup.desktop(root, stale) end)

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    startup = Task.async(fn -> Rekindle.Development.Cleanup.startup(project) end)
    discard = Task.async(fn -> Rekindle.Development.Cleanup.discard(project, stale) end)

    refute_receive {DesktopDevelopment, {:ready, ^selected}}, 200
    assert Task.yield(cleanup, 100) == nil
    assert Task.yield(startup, 100) == nil
    assert Task.yield(discard, 100) == nil
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-last-running.json"))

    File.write!(release, "release")
    assert_receive {^port, {:exit_status, 0}}, 5_000
    assert :ok = Task.await(cleanup, 5_000)
    assert :ok = Task.await(startup, 5_000)
    assert :ok = Task.await(discard, 5_000)
    assert_receive {DesktopDevelopment, {:ready, ^selected}}, 5_000

    marker = read_marker(root)
    assert marker["generation"] == selected.metadata.generation
    assert marker["target"] == selected.metadata.rust_target
    assert File.dir?(Path.dirname(selected.metadata.manifest))
  end

  @tag capture_log: true
  test "keeps the desktop marker valid across competing launchers", %{root: root} do
    supervisor_a =
      start_supervised!(
        Supervisor.child_spec(
          {DynamicSupervisor, strategy: :one_for_one},
          id: :desktop_supervisor_a
        )
      )

    supervisor_b =
      start_supervised!(
        Supervisor.child_spec(
          {DynamicSupervisor, strategy: :one_for_one},
          id: :desktop_supervisor_b
        )
      )

    launcher_a = start_launcher(root, supervisor_a, :desktop_launcher_a)
    launcher_b = start_launcher(root, supervisor_b, :desktop_launcher_b)
    first = desktop_result(root, "competing-first", :running)
    second = desktop_result(root, "competing-second", :running)

    generation_root =
      Path.join([
        root,
        ".rekindle",
        "dev",
        "desktop",
        Rekindle.Toolchain.desktop_target()
      ])

    for value <- 1..20 do
      generation =
        :sha256
        |> :crypto.hash(Integer.to_string(value))
        |> Base.encode16(case: :lower)

      path = Path.join(generation_root, generation)
      File.mkdir_p!(path)
      File.touch!(path, {{2030, 1, 1}, {0, 0, value}})
    end

    DesktopDevelopment.replace(launcher_a, first)
    DesktopDevelopment.replace(launcher_b, second)

    events =
      for _index <- 1..2 do
        assert_receive {DesktopDevelopment, event}, 5_000
        event
      end

    assert Enum.any?(events, &match?({:ready, _result}, &1))

    marker = read_marker(root)
    selected = Enum.find([first, second], &(&1.metadata.generation == marker["generation"]))
    assert selected
    assert marker["target"] == selected.metadata.rust_target
    assert File.dir?(Path.dirname(selected.metadata.manifest))

    manifest =
      selected.metadata.manifest
      |> File.read!()
      |> Jason.decode!()

    assert :ok =
             Rekindle.Desktop.Manifest.validate(
               Path.dirname(selected.metadata.manifest),
               manifest
             )

    assert length(File.ls!(generation_root)) == 2
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
    marker = Path.join([root, ".rekindle", "dev", ".tmp-web-current-abandoned"])
    error_temporary = Path.join([root, ".rekindle", "dev", ".tmp-web-error-abandoned"])
    unrelated = Path.join([root, ".rekindle", "dev", "application-state"])

    desktop_marker =
      Path.join([root, ".rekindle", "dev", ".tmp-desktop-last-running-abandoned"])

    File.mkdir_p!(temporary)
    File.write!(Path.join(temporary, "partial"), "partial")
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, "partial")
    File.write!(error_temporary, "partial")
    File.write!(unrelated, "keep")
    File.write!(desktop_marker, "partial")

    selected = publish_web(root, "export default 'selected';")
    web_root = Path.join([root, ".rekindle", "dev", "web"])
    selector = Path.join([root, ".rekindle", "dev", "web-current.json"])
    selected_selector = File.read!(selector)

    for value <- ["c", "d", "e"] do
      generation = String.duplicate(value, 64)
      File.mkdir_p!(Path.join(web_root, generation))
      File.touch!(Path.join(web_root, generation))
    end

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert :ok = Rekindle.Development.Cleanup.startup(project)
    assert :ok = Rekindle.Development.Cleanup.startup(project)
    refute File.exists?(Path.join([root, ".rekindle", "tmp"]))
    refute File.exists?(marker)
    refute File.exists?(error_temporary)
    refute File.exists?(desktop_marker)
    assert File.read!(unrelated) == "keep"
    assert File.read!(selector) == selected_selector
    assert File.dir?(Path.join(web_root, selected))
    assert length(Path.wildcard(Path.join(web_root, String.duplicate("?", 64)))) == 2
  end

  @tag capture_log: true
  test "skips linked and special selectors during startup cleanup without blocking", %{root: root} do
    generation = publish_web(root, "export default 'selected';")
    desktop = desktop_result(root, "selected-cleanup", :running)
    selector = Path.join(root, ".rekindle/dev/web-current.json")
    marker = Path.join(root, ".rekindle/dev/desktop-last-running.json")

    File.write!(
      marker,
      Jason.encode!(%{
        "generation" => desktop.metadata.generation,
        "target" => desktop.metadata.rust_target,
        "manifest" =>
          Path.relative_to(desktop.metadata.manifest, Path.join(root, ".rekindle/dev"))
      })
    )

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    for kind <- [:symlink, :fifo] do
      with_special_file(selector, kind, Jason.encode!(%{"generation" => generation}), fn ->
        with_special_file(marker, kind, "{}", fn ->
          assert {:ok, :ok} = bounded(fn -> Rekindle.Development.Cleanup.startup(project) end)
        end)
      end)
    end
  end

  test "does not read or mutate development state through a linked state root", %{root: root} do
    external = Path.join(root, "external-state")
    temporary = Path.join([external, "tmp", "web", "abandoned"])
    marker = Path.join([external, "dev", ".tmp-web-current-abandoned"])
    error = Path.join([external, "dev", "web-error.json"])
    File.mkdir_p!(temporary)
    File.write!(Path.join(temporary, "partial"), "unchanged")
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, "unchanged")
    File.write!(error, Jason.encode!(%{"error" => "retained"}))
    File.ln_s!(external, Path.join(root, ".rekindle"))

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert :ok = Rekindle.Development.Cleanup.startup(project)
    assert :ok = Development.put_error(project, "must not escape")
    assert :ok = Development.clear_error(project)

    assert File.read!(Path.join(temporary, "partial")) == "unchanged"
    assert File.read!(marker) == "unchanged"
    assert Jason.decode!(File.read!(error)) == %{"error" => "retained"}
  end

  test "startup cleanup waits for live staging in independent VMs", %{root: root} do
    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    for target <- [:web, :desktop] do
      staging = Path.join([root, ".rekindle", "tmp", Atom.to_string(target), "active"])
      ready = Path.join(root, "#{target}-staging.ready")
      release = Path.join(root, "#{target}-staging.release")
      port = staging_process(root, target, staging, ready, release)

      on_exit(fn ->
        File.write(release, "release")
        if Port.info(port), do: Port.close(port)
      end)

      assert_until(fn -> File.regular?(ready) end, 200)

      other = if target == :web, do: :desktop, else: :web

      assert :independent =
               Rekindle.Publication.with_lock(
                 root,
                 {:staging, other},
                 fn -> :independent end,
                 50
               )

      cleanup = Task.async(fn -> Rekindle.Development.Cleanup.startup(project) end)
      assert Task.yield(cleanup, 100) == nil
      assert File.dir?(staging)

      File.write!(release, "release")
      assert_receive {^port, {:exit_status, 0}}, 5_000
      assert :ok = Task.await(cleanup, 5_000)
      refute File.exists?(staging)
    end
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

  defp publish_web(root, source), do: publish_web_members(root, %{"app.js" => source})

  defp publish_web_members(root, members) do
    temporary = Path.join(root, "web-source")
    File.rm_rf!(temporary)

    Enum.each(members, fn {path, contents} ->
      destination = Path.join(temporary, path)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, contents)
    end)

    {:ok, manifest} = Rekindle.Web.Manifest.create(temporary, "app.js")
    generation = manifest["generation"]
    generation_root = Path.join([root, ".rekindle", "dev", "web", generation])
    File.mkdir_p!(generation_root)

    Enum.each(members, fn {path, contents} ->
      destination = Path.join(generation_root, path)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, contents)
    end)

    File.write!(Path.join(generation_root, "manifest.json"), Jason.encode!(manifest))

    select_web(root, generation)

    generation
  end

  defp external_path(root, name) do
    root <> "-external-#{name}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp select_web(root, generation) do
    File.write!(
      Path.join(root, ".rekindle/dev/web-current.json"),
      Jason.encode!(%{"generation" => generation})
    )
  end

  defp selected_web(root) do
    root
    |> Path.join(".rekindle/dev/web-current.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("generation")
  end

  defp web_result(root, generation) do
    generation_root = Path.join([root, ".rekindle", "dev", "web", generation])

    %Result{
      target: :web,
      profile: :dev,
      artifact: Path.join(generation_root, "app.js"),
      metadata: %{
        generation: generation,
        manifest: Path.join(generation_root, "manifest.json")
      }
    }
  end

  defp assert_valid_web_generation(root, generation) do
    generation_root = Path.join([root, ".rekindle", "dev", "web", generation])

    manifest =
      generation_root
      |> Path.join("manifest.json")
      |> File.read!()
      |> Jason.decode!()

    assert :ok = Rekindle.Web.Manifest.validate(generation_root, manifest)
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

  defp browser_selector(generation, module) do
    Jason.encode!(%{
      generation: generation,
      entry: "data:text/javascript,#{URI.encode(module)}"
    })
  end

  defp run_browser_responses(root, integration, setup, transform, responses) do
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

    page =
      """
      <!doctype html>
      <html><body>
        <canvas id="the_canvas_id"></canvas>
        <canvas id="canvas"></canvas>
        <pre id="rekindle-error" hidden></pre>
        <script>
          #{setup}
          const responses = #{Jason.encode!(responses)};
          let requests = 0;
          const originalConsoleError = console.error.bind(console);
          console.error = (...values) => {
            const error = values.find((value) => value instanceof Error);
            const message = error ? `${error.name}: ${error.message}` : values.join(" ");
            const root = document.documentElement;
            root.dataset.rekindleErrorCount =
              String(Number(root.dataset.rekindleErrorCount || "0") + 1);
            root.dataset.rekindleErrors =
              [root.dataset.rekindleErrors, message].filter(Boolean).join(" | ");
            originalConsoleError(...values);
          };
          window.fetch = () => {
            const index = Math.min(requests, responses.length - 1);
            const response = responses[index];
            requests += 1;
            document.documentElement.dataset.requests = String(requests);
            return new Promise((resolve, reject) => {
              window.setTimeout(() => {
                if (typeof response === "object" && response.reject) {
                  reject(new TypeError(response.reject));
                  return;
                }
                resolve(
                  new Response(response, {
                    status: 200,
                    headers: {"content-type": "application/json"}
                  })
                );
              }, typeof response === "object" ? response.delay || 0 : 0);
            });
          };
        </script>
        <script type="module">#{runtime}</script>
      </body></html>
      """

    directory =
      Path.join(
        root,
        "browser-responses-#{integration}-#{System.unique_integer([:positive, :monotonic])}"
      )

    profile = Path.join(directory, "profile")
    File.mkdir_p!(directory)
    page_path = Path.join(directory, "index.html")
    File.write!(page_path, page)

    arguments = [
      "--headless=new",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--allow-file-access-from-files",
      "--user-data-dir=#{profile}",
      "--virtual-time-budget=1250",
      "--dump-dom",
      "file://#{page_path}"
    ]

    assert {:ok, %{status: 0, output: output}} =
             Rekindle.Toolchain.Process.run(browser, arguments,
               cd: directory,
               timeout: 20_000,
               output_limit: 1_000_000
             )

    output
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
        <canvas id="the_canvas_id"></canvas>
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
      "--disable-gpu",
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

  defp start_development_httpd(root, port) do
    :inets.start(:httpd,
      bind_address: ~c"127.0.0.1",
      port: port,
      server_name: ~c"rekindle-development-recovery-test",
      server_root: String.to_charlist(root),
      document_root: String.to_charlist(root),
      modules: [:mod_alias, :mod_dir, :mod_get, :mod_head],
      directory_index: [~c"index.html"],
      mime_types: [
        {~c"html", ~c"text/html"},
        {~c"js", ~c"text/javascript"}
      ]
    )
  end

  defp development_browser_state(port, session) do
    IntegrationBrowser.webdriver_request!(
      :post,
      port,
      "/session/#{session}/execute/sync",
      %{
        "script" => """
        const root = document.documentElement.dataset;
        return {
          applicationStarted: root.applicationStarted || null,
          initializers: root.initializers || null,
          errorCount: Number(root.rekindleErrorCount || "0"),
          errors: root.rekindleErrors || ""
        };
        """,
        "args" => []
      }
    )["value"]
  end

  defp start_launcher(root, supervisor) do
    start_launcher(root, supervisor, DesktopDevelopment)
  end

  defp start_launcher(root, supervisor, id) do
    start_supervised!(
      Supervisor.child_spec(
        {DesktopDevelopment,
         project_root: root, supervisor: supervisor, readiness: 75, notify: self()},
        id: id
      )
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
    target = Rekindle.Toolchain.desktop_target()
    temporary = Path.join(root, "#{name}-generation")
    File.mkdir_p!(temporary)
    executable = "desktop"
    artifact = Path.join(temporary, executable)
    File.cp!(source, artifact)
    File.chmod!(artifact, 0o755)

    {:ok, manifest} =
      Rekindle.Desktop.Manifest.create(
        temporary,
        executable,
        target,
        "client",
        "desktop",
        :gpui
      )

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

  defp staging_process(root, target, staging, ready, release) do
    publication_lock_process(root, {:staging, target}, ready, release, staging)
  end

  defp publication_lock_process(root, key, ready, release, directory \\ nil) do
    elixir = System.find_executable("elixir") || flunk("elixir executable is required")

    arguments =
      {root, key, ready, release, directory}
      |> :erlang.term_to_binary()
      |> Base.encode64()

    expression = """
    {root, key, ready, release, directory} =
      #{inspect(arguments)}
      |> Base.decode64!()
      |> :erlang.binary_to_term()

    Rekindle.Publication.with_lock(root, key, fn ->
      if directory, do: File.mkdir_p!(directory)
      File.write!(ready, "ready")

      wait = fn wait ->
        if File.regular?(release) do
          :ok
        else
          Process.sleep(10)
          wait.(wait)
        end
      end

      wait.(wait)
    end)
    """

    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&[~c"-pa", String.to_charlist(&1)])

    Port.open(
      {:spawn_executable, String.to_charlist(elixir)},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: code_paths ++ [~c"-e", String.to_charlist(expression)]
      ]
    )
  end

  defp read_marker(root) do
    root
    |> Path.join(".rekindle/dev/desktop-last-running.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp bounded(function) do
    task = Task.async(function)
    Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
  end

  defp with_special_file(path, kind, fallback, function) do
    backup = path <> ".special-backup"
    existed? = File.exists?(path)

    if existed? do
      File.rename!(path, backup)
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(backup, fallback)
    end

    case kind do
      :symlink -> File.ln_s!(Path.basename(backup), path)
      :fifo -> assert {"", 0} = System.cmd("mkfifo", [path])
    end

    try do
      function.()
    after
      if match?({:ok, _stat}, File.lstat(path)), do: File.rm!(path)

      if existed? and match?({:ok, _stat}, File.lstat(backup)) do
        File.rename!(backup, path)
      else
        if match?({:ok, _stat}, File.lstat(backup)), do: File.rm!(backup)
      end
    end
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
