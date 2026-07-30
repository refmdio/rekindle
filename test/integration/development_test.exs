defmodule Rekindle.DevelopmentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Rekindle.Build.Result
  alias Rekindle.Development.Builder
  alias Rekindle.Development.Socket
  alias Rekindle.Desktop.Development, as: DesktopDevelopment
  alias Rekindle.DevServer

  defmodule BrowserPlug do
    @behaviour Plug

    import Plug.Conn

    alias Rekindle.DevelopmentTest.ClosingSocket
    alias Rekindle.DevServer

    @impl Plug
    def init(options), do: options

    @impl Plug
    def call(%Plug.Conn{path_info: ["@rekindle", "socket"]} = conn, %{socket: :close}) do
      conn
      |> WebSockAdapter.upgrade(ClosingSocket, nil, timeout: :infinity)
      |> halt()
    end

    def call(conn, options) do
      conn = DevServer.call(conn, options.dev_server)

      if conn.halted do
        conn
      else
        dispatch(conn, options)
      end
    end

    defp dispatch(%Plug.Conn{method: "GET", path_info: []} = conn, options) do
      send(options.test, :browser_document_requested)

      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, page(options.socket))
    end

    defp dispatch(
           %Plug.Conn{method: "POST", path_info: ["__test", "loaded", label]} = conn,
           options
         ) do
      send(options.test, {:browser_loaded, label})
      send_resp(conn, 204, "")
    end

    defp dispatch(
           %Plug.Conn{method: "POST", path_info: ["__test", "delays"]} = conn,
           options
         ) do
      {:ok, body, conn} = read_body(conn)
      send(options.test, {:browser_reconnect_delays, Jason.decode!(body)})
      send_resp(conn, 204, "")
    end

    defp dispatch(conn, _options), do: send_resp(conn, 404, "Not found")

    defp page(:reload) do
      """
      <!doctype html>
      <html>
        <body>
          <script type="module" src="/@rekindle/runtime.js"></script>
        </body>
      </html>
      """
    end

    defp page(:close) do
      """
      <!doctype html>
      <html>
        <body>
          <script>
            const nativeSetTimeout = window.setTimeout.bind(window);
            const reconnectDelays = [];
            window.setTimeout = (callback, delay, ...args) => {
              if (callback.name === "connect") {
                reconnectDelays.push(delay);
                if (reconnectDelays.length === 4) {
                  fetch("/__test/delays", {
                    method: "POST",
                    body: JSON.stringify(reconnectDelays)
                  });
                }
                return nativeSetTimeout(callback, 0, ...args);
              }
              return nativeSetTimeout(callback, delay, ...args);
            };
          </script>
          <script type="module" src="/@rekindle/runtime.js"></script>
        </body>
      </html>
      """
    end
  end

  defmodule ClosingSocket do
    @behaviour WebSock

    @impl WebSock
    def init(state) do
      send(self(), :close)
      {:ok, state}
    end

    @impl WebSock
    def handle_in(_message, state), do: {:ok, state}

    @impl WebSock
    def handle_info(:close, state), do: {:stop, :normal, state}

    def handle_info(_message, state), do: {:ok, state}
  end

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
      plugin: Rekindle.Plugin.GPUI,
      targets: [web: [], desktop: []]
    )

    on_exit(fn ->
      Application.delete_env(:rekindle_development_test, Rekindle)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "builds different targets concurrently", %{root: root} do
    test = self()

    build = fn target, _options ->
      send(test, {:started, target, self()})

      receive do
        :finish -> {:ok, result(root, target, Atom.to_string(target))}
      end
    end

    builder = start_builder(root, build)
    Builder.rebuild(builder, :all)

    assert_receive {:started, :web, web}
    assert_receive {:started, :desktop, desktop}
    refute web == desktop

    send(web, :finish)
    send(desktop, :finish)

    assert_receive {Builder, :web, {:ok, %Result{target: :web}}}
    assert_receive {Builder, :desktop, {:ok, %Result{target: :desktop}}}
  end

  test "finishes the active build and queues one newer build", %{root: root} do
    test = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    build = fn target, _options ->
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test, {:started, attempt, self()})

      receive do
        :finish -> {:ok, result(root, target, Integer.to_string(attempt))}
      end
    end

    builder = start_builder(root, build)
    Builder.rebuild(builder, :web)
    assert_receive {:started, 1, first}

    Builder.rebuild(builder, :web)
    Builder.rebuild(builder, :web)
    refute_receive {:started, 2, _pid}, 30

    send(first, :finish)
    assert_receive {Builder, :web, {:ok, %Result{metadata: %{generation: "1"}}}}
    assert_receive {:started, 2, second}

    send(second, :finish)
    assert_receive {Builder, :web, {:ok, %Result{metadata: %{generation: "2"}}}}
    refute_receive {:started, 3, _pid}, 30
  end

  test "reports completion before a queued replacement starts", %{root: root} do
    test = self()

    build = fn target, _options ->
      send(test, {:started, self()})

      receive do
        :finish -> {:ok, result(root, target, "generation")}
      end
    end

    log =
      capture_log(fn ->
        builder = start_builder(root, build)
        Builder.rebuild(builder, :web)
        assert_receive {:started, first}

        Builder.rebuild(builder, :web)
        send(first, :finish)
        assert_receive {Builder, :web, {:ok, %Result{}}}
        assert_receive {:started, second}

        send(second, :finish)
        assert_receive {Builder, :web, {:ok, %Result{}}}
      end)

    events =
      log
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "Rekindle Web"))
      |> Enum.map(&Regex.replace(~r/^.*\] /, &1, ""))

    assert [
             "Building Rekindle Web...",
             "Built Rekindle Web" <> _first_duration,
             "Building Rekindle Web...",
             "Built Rekindle Web" <> _second_duration
           ] = events
  end

  test "replaces the desktop process and removes its previous output", %{root: root} do
    supervisor =
      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, name: desktop_supervisor_name()}
      )

    launcher =
      start_supervised!(
        {DesktopDevelopment,
         project_root: root, supervisor: supervisor, notify: self(), name: desktop_launcher_name()}
      )

    first = desktop_result(root, "first")
    DesktopDevelopment.replace(launcher, first)
    assert_receive {DesktopDevelopment, {:ready, ^first}}

    %{current: %{pid: first_process}} = DesktopDevelopment.status(launcher)
    assert Process.alive?(first_process)
    assert File.regular?(first.artifact)

    second = desktop_result(root, "second")
    DesktopDevelopment.replace(launcher, second)
    assert_receive {DesktopDevelopment, {:ready, ^second}}

    refute Process.alive?(first_process)
    refute File.exists?(Path.dirname(first.artifact))
    assert %{current: %{result: ^second}} = DesktopDevelopment.status(launcher)
  end

  test "clears desktop state when the replacement exits", %{root: root} do
    supervisor =
      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, name: desktop_supervisor_name()}
      )

    launcher =
      start_supervised!(
        {DesktopDevelopment,
         project_root: root, supervisor: supervisor, notify: self(), name: desktop_launcher_name()}
      )

    first = desktop_result(root, "first")
    DesktopDevelopment.replace(launcher, first)
    assert_receive {DesktopDevelopment, {:ready, ^first}}
    %{current: %{pid: first_process}} = DesktopDevelopment.status(launcher)

    replacement = desktop_result(root, "replacement", :exit)

    error_log =
      capture_log([level: :error], fn ->
        DesktopDevelopment.replace(launcher, replacement)
        assert_receive {DesktopDevelopment, {:ready, ^replacement}}
        assert_receive {DesktopDevelopment, {:exited, ^replacement, :normal}}
      end)

    refute Process.alive?(first_process)
    refute error_log =~ "desktop development process exited"
    assert DesktopDevelopment.status(launcher) == %{current: nil}
    refute File.exists?(Path.dirname(first.artifact))
    refute File.exists?(Path.dirname(replacement.artifact))
  end

  test "routes build notifications by target", %{root: root} do
    build = fn target, _options ->
      {:ok, result(root, target, Atom.to_string(target))}
    end

    builder = start_builder(root, build, %{desktop: self()})
    Builder.rebuild(builder, :all)

    assert_receive {Builder, :desktop, {:ok, %Result{target: :desktop}}}
    refute_receive {Builder, :web, _result}, 50
  end

  test "pushes Web development state and serves generation assets", %{root: root} do
    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert Rekindle.Development.State.web_status(project) == %{"type" => "pending"}

    generation = publish_web(root, "export default async function init() {}")

    options =
      DevServer.init(otp_app: :rekindle_development_test, project_root: root, watch: false)

    upgrade =
      Plug.Test.conn("GET", "http://example.test/@rekindle/socket")
      |> Map.update!(:req_headers, &[{"host", "example.test"} | &1])
      |> Plug.Conn.put_req_header("connection", "upgrade")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.put_req_header(
        "sec-websocket-key",
        Base.encode64(:crypto.strong_rand_bytes(16))
      )
      |> Plug.Conn.put_req_header("sec-websocket-version", "13")
      |> DevServer.call(options)

    assert upgrade.state == :upgraded
    assert upgrade.halted

    assert {:push, {:text, initial}, ^project} = Socket.init(project)

    assert Jason.decode!(initial) == %{
             "type" => "current_generation",
             "generation" => generation,
             "entry" => "/@rekindle/web/#{generation}/app.js"
           }

    asset = request("/@rekindle/web/#{generation}/app.js", options)
    assert asset.status == 200
    assert asset.resp_body == "export default async function init() {}"

    wasm = request("/@rekindle/web/#{generation}/app_bg.wasm", options)
    assert wasm.status == 200
    assert Plug.Conn.get_resp_header(wasm, "content-type") == ["application/wasm"]

    runtime = request("/@rekindle/runtime.js", options)
    assert runtime.status == 200
    assert runtime.resp_body =~ "navigator.gpu"
    assert runtime.resp_body =~ "await module.default();"
    assert runtime.resp_body =~ ~s(id = "rekindle-status")
    assert runtime.resp_body =~ ~s(new CustomEvent("rekindle:ready")
    assert runtime.resp_body =~ ~s(new CustomEvent("rekindle:before-reload")
    assert runtime.resp_body =~ ~s(new CustomEvent("rekindle:error")
    assert runtime.resp_body =~ "if (reportedError === identity) return;"
    assert runtime.resp_body =~ "if (attemptedGeneration === state.generation) return;"
    assert runtime.resp_body =~ "const socket = new WebSocket(socketUrl);"
    assert runtime.resp_body =~ ~s(socket.addEventListener("message")
    assert runtime.resp_body =~ "reconnectDelay = Math.min(reconnectDelay * 2, 5000);"
    assert runtime.resp_body =~ ~s(["pending", "build_failed", "current_generation"])
    assert runtime.resp_body =~ "reloading = true;"
    refute runtime.resp_body =~ "setInterval"
    refute runtime.resp_body =~ "./current"

    assert runtime.resp_body =~
             ~S|for (const level of ["log", "info", "warn", "error", "debug"])|

    assert runtime.resp_body =~ "const result = originals[level](...args);"
    assert runtime.resp_body =~ "return result;"
    assert runtime.resp_body =~ "navigator.sendBeacon(consoleUrl, body)"
    assert runtime.resp_body =~ "}).catch(() => {});"
    assert runtime.resp_body =~ ~S|window.addEventListener("error"|
    assert runtime.resp_body =~ ~S|window.addEventListener("unhandledrejection"|
    assert runtime.resp_body =~ "{forward: false}"
    assert runtime.resp_body =~ "function report(error, key, {forward = true} = {})"

    assert :ok = Rekindle.Development.State.put_error(project, "Rust compilation failed")
    assert_receive {Rekindle.Development.State, :changed}

    assert {:push, {:text, failure}, ^project} =
             Socket.handle_info({Rekindle.Development.State, :changed}, project)

    assert Jason.decode!(failure) == %{
             "type" => "build_failed",
             "error" => "Rust compilation failed"
           }

    assert :ok = Rekindle.Development.State.clear_error(project)
    assert_receive {Rekindle.Development.State, :changed}

    assert {:push, {:text, recovered}, ^project} =
             Socket.handle_info({Rekindle.Development.State, :changed}, project)

    assert Jason.decode!(recovered)["type"] == "current_generation"
    assert {:ok, ^project} = Socket.handle_in({"ignored", opcode: :text}, project)
  end

  test "reloads a live browser when the WebSocket pushes a new generation", %{root: root} do
    Application.put_env(:rekindle_development_test, Rekindle,
      plugin: Rekindle.Plugin.Egui,
      targets: [web: [], desktop: []]
    )

    first =
      publish_web(root, """
      export default async function init() {
        document.documentElement.dataset.generation = "first";
        await fetch("/__test/loaded/first", {method: "POST"});
      }
      """)

    {browser, url, browser_directory} = start_browser_server(root, :reload)

    on_exit(fn -> File.rm_rf(browser_directory) end)

    browser_process = run_browser(browser, url, browser_directory)

    assert_receive :browser_document_requested, 10_000
    assert_receive {:browser_loaded, "first"}, 10_000

    second =
      publish_web(root, """
      export default async function init() {
        document.documentElement.dataset.generation = "second";
        await fetch("/__test/loaded/second", {method: "POST"});
      }
      """)

    refute first == second

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert :ok = Rekindle.Development.State.clear_error(project)
    assert_receive :browser_document_requested, 10_000
    assert_receive {:browser_loaded, "second"}, 10_000
    assert Process.alive?(browser_process)
  end

  test "backs off repeated WebSocket connections that close before state arrives", %{root: root} do
    Application.put_env(:rekindle_development_test, Rekindle,
      plugin: Rekindle.Plugin.Egui,
      targets: [web: [], desktop: []]
    )

    {browser, url, browser_directory} = start_browser_server(root, :close)

    on_exit(fn -> File.rm_rf(browser_directory) end)

    browser_process = run_browser(browser, url, browser_directory)

    assert_receive {:browser_reconnect_delays, [250, 500, 1000, 2000]}, 10_000
    assert Process.alive?(browser_process)
  end

  test "forwards browser console messages to Logger levels", %{root: root} do
    options =
      DevServer.init(otp_app: :rekindle_development_test, project_root: root, watch: false)

    for {browser_level, logger_level} <- [
          {"log", :info},
          {"info", :info},
          {"warn", :warning},
          {"error", :error},
          {"debug", :debug}
        ] do
      log =
        capture_log([level: logger_level], fn ->
          response =
            post(
              "/@rekindle/console",
              %{
                "level" => browser_level,
                "source" => "console",
                "args" => ["message", ~s({"answer":42})]
              },
              options
            )

          assert response.status == 204
        end)

      assert log =~ "[browser console] message {\"answer\":42}"
    end

    assert post("/@rekindle/console", %{"level" => "trace"}, options).status == 400
  end

  test "marks browser logs with their Logger domain", %{root: root} do
    options =
      DevServer.init(otp_app: :rekindle_development_test, project_root: root, watch: false)

    log =
      capture_log([metadata: [:domain]], fn ->
        assert post(
                 "/@rekindle/console",
                 %{"level" => "info", "source" => "console", "args" => ["round trip"]},
                 options
               ).status == 204
      end)

    assert log =~ "domain=elixir.rekindle.browser"
    assert log =~ "[browser console] round trip"
  end

  test "starts one supervised Web runtime from requests", %{root: root} do
    File.write!(Path.join(root, "client/Cargo.toml"), """
    [package]
    name = "request-driven-client"
    version = "0.1.0"
    edition = "2024"

    [features]
    web = []

    [[bin]]
    name = "web"
    path = "src/bin/web.rs"
    required-features = ["web"]
    """)

    Application.put_env(:rekindle_request_driven_test, Rekindle,
      plugin: Rekindle.Plugin.GPUI,
      targets: [web: []]
    )

    on_exit(fn ->
      Application.delete_env(:rekindle_request_driven_test, Rekindle)

      case Registry.lookup(Rekindle.Development.Registry, :rekindle_request_driven_test) do
        [{pid, _value}] ->
          DynamicSupervisor.terminate_child(Rekindle.Development.DynamicSupervisor, pid)

        [] ->
          :ok
      end
    end)

    options =
      DevServer.init(otp_app: :rekindle_request_driven_test, project_root: root)

    assert request("/", options).status == nil

    assert [{runtime, _value}] =
             Registry.lookup(
               Rekindle.Development.Registry,
               :rekindle_request_driven_test
             )

    assert request("/", options).status == nil

    assert [{^runtime, _value}] =
             Registry.lookup(
               Rekindle.Development.Registry,
               :rekindle_request_driven_test
             )
  end

  test "startup cleanup is limited to the selected development targets", %{root: root} do
    first = publish_web(root, "export default 1")
    second = publish_web(root, "export default 2")
    selected = publish_web(root, "export default 3")

    web_temporary = Path.join(root, ".rekindle/tmp/web/incomplete")
    desktop_temporary = Path.join(root, ".rekindle/tmp/desktop/incomplete")
    desktop_output = Path.join(root, ".rekindle/dev/desktop/target/current")
    File.mkdir_p!(web_temporary)
    File.mkdir_p!(desktop_temporary)
    File.mkdir_p!(desktop_output)

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert :ok = Rekindle.Development.Cleanup.startup(project, [:web])
    refute File.exists?(web_temporary)
    assert File.dir?(desktop_temporary)
    assert File.dir?(desktop_output)
    assert File.dir?(Path.join([root, ".rekindle/dev/web", selected]))

    assert web_generations(root) == MapSet.new([first, second, selected])

    assert :ok = Rekindle.Development.Cleanup.startup(project, [:desktop])
    refute File.exists?(desktop_temporary)
    refute File.exists?(desktop_output)
    assert File.dir?(Path.join([root, ".rekindle/dev/web", selected]))
  end

  test "stopping the builder also stops its active task", %{root: root} do
    test = self()

    build = fn _target, _options ->
      send(test, {:build_started, self()})
      receive do: (:never -> :ok)
    end

    builder = start_builder(root, build)
    Builder.rebuild(builder, :web)
    assert_receive {:build_started, task}
    monitor = Process.monitor(task)

    stop_supervised(Builder)
    assert_receive {:DOWN, ^monitor, :process, ^task, _reason}
  end

  defp start_builder(root, build, notify \\ nil) do
    start_supervised!(
      {Builder,
       otp_app: :rekindle_development_test,
       project_root: root,
       debounce: 10,
       notify: notify || self(),
       build: build,
       activate: fn _result -> :ok end}
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
    temporary =
      Path.join(root, "web-source-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(temporary)
    File.write!(Path.join(temporary, "app.js"), source)
    File.write!(Path.join(temporary, "app_bg.wasm"), <<0, 97, 115, 109>>)

    generation =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    destination = Path.join([root, ".rekindle", "dev", "web", generation])
    File.mkdir_p!(Path.dirname(destination))
    File.rename!(temporary, destination)
    File.mkdir_p!(Path.join(root, ".rekindle/dev"))

    File.write!(
      Path.join(root, ".rekindle/dev/web-current.json"),
      Jason.encode!(%{"generation" => generation})
    )

    generation
  end

  defp desktop_result(root, name, behavior \\ :running) do
    {:ok, target} = Rekindle.Toolchain.host_target()
    directory = Path.join([root, ".rekindle", "dev", "desktop", target, name])
    File.mkdir_p!(directory)
    artifact = Path.join(directory, "application")

    body =
      case behavior do
        :running -> "#!/bin/sh\nwhile true; do sleep 1; done\n"
        :exit -> "#!/bin/sh\nexit 0\n"
      end

    File.write!(artifact, body)

    File.chmod!(artifact, 0o755)

    {:ok, manifest} =
      Rekindle.Desktop.Manifest.create(
        directory,
        "application",
        target,
        "client",
        "desktop",
        "gpui"
      )

    manifest_path = Path.join(directory, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    %Result{
      target: :desktop,
      profile: :dev,
      artifact: artifact,
      metadata: %{manifest: manifest_path, rust_target: target}
    }
  end

  defp request(path, options) do
    Plug.Test.conn("GET", path)
    |> DevServer.call(options)
  end

  defp post(path, body, options) do
    Plug.Test.conn("POST", path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> DevServer.call(options)
  end

  defp start_browser_server(root, socket) do
    browser =
      Enum.find_value(
        ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"],
        fn
          executable -> System.find_executable(executable)
        end
      ) || flunk("a Chromium executable is required for development browser integration tests")

    dev_server =
      DevServer.init(otp_app: :rekindle_development_test, project_root: root, watch: false)

    server =
      start_supervised!(
        {Bandit,
         plug: {BrowserPlug, %{dev_server: dev_server, socket: socket, test: self()}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    browser_directory =
      Path.join(
        System.tmp_dir!(),
        "rekindle-chromium-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(browser_directory)
    {browser, "http://127.0.0.1:#{port}/", browser_directory}
  end

  defp run_browser(browser, url, browser_directory) do
    child =
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           browser,
           [
             "--headless=new",
             "--no-sandbox",
             "--no-first-run",
             "--no-default-browser-check",
             "--disable-dev-shm-usage",
             "--disable-gpu",
             "--enable-webgl",
             "--enable-unsafe-swiftshader",
             "--ignore-gpu-blocklist",
             "--use-angle=swiftshader",
             "--user-data-dir=#{browser_directory}",
             "--remote-debugging-port=0",
             url
           ],
           [stderr_to_stdout: true]
         ]},
        id: {:chromium, System.unique_integer([:positive, :monotonic])}
      )

    start_supervised!(child)
  end

  defp web_generations(root) do
    root
    |> Path.join(".rekindle/dev/web")
    |> File.ls!()
    |> Enum.filter(&(&1 =~ ~r/^[0-9a-f]{32}$/))
    |> MapSet.new()
  end

  defp desktop_supervisor_name,
    do: Module.concat(__MODULE__, "DesktopSupervisor#{System.unique_integer([:positive])}")

  defp desktop_launcher_name,
    do: Module.concat(__MODULE__, "DesktopLauncher#{System.unique_integer([:positive])}")
end
