defmodule Rekindle.DevelopmentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Rekindle.Build.Result
  alias Rekindle.Development.Builder
  alias Rekindle.Desktop.Development, as: DesktopDevelopment
  alias Rekindle.Phoenix.Development

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

  test "serves the selected Web generation and reports build errors", %{root: root} do
    generation = publish_web(root, "export default async function init() {}")
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)

    current = request("/__rekindle/current", options)

    assert current.status == 200

    assert Jason.decode!(current.resp_body) == %{
             "generation" => generation,
             "entry" => "/__rekindle/web/#{generation}/app.js"
           }

    asset = request("/__rekindle/web/#{generation}/app.js", options)
    assert asset.status == 200
    assert asset.resp_body == "export default async function init() {}"

    runtime = request("/__rekindle/runtime.js", options)
    assert runtime.status == 200
    assert runtime.resp_body =~ "navigator.gpu"
    assert runtime.resp_body =~ "await module.default();"
    assert runtime.resp_body =~ ~s(id = "rekindle-status")
    assert runtime.resp_body =~ ~s(new CustomEvent("rekindle:ready")
    assert runtime.resp_body =~ ~s(new CustomEvent("rekindle:before-reload")
    assert runtime.resp_body =~ ~s(new CustomEvent("rekindle:error")
    assert runtime.resp_body =~ "if (reportedError === identity) return;"
    assert runtime.resp_body =~ "if (attemptedGeneration === current.generation) return;"
    assert runtime.resp_body =~ "if (loading || reloading) return;"
    assert runtime.resp_body =~ "reloading = true;"

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert :ok = Development.put_error(project, "Rust compilation failed")
    failure = request("/__rekindle/current", options)
    assert failure.status == 409
    assert Jason.decode!(failure.resp_body) == %{"error" => "Rust compilation failed"}

    assert :ok = Development.clear_error(project)
    assert request("/__rekindle/current", options).status == 200
  end

  test "startup cleanup removes disposable state and keeps the selected Web output", %{root: root} do
    first = publish_web(root, "export default 1")
    second = publish_web(root, "export default 2")
    selected = publish_web(root, "export default 3")

    File.mkdir_p!(Path.join(root, ".rekindle/tmp/web/incomplete"))
    File.mkdir_p!(Path.join(root, ".rekindle/dev/desktop/target/stale"))

    {:ok, project} =
      Rekindle.Config.load(:rekindle_development_test, project_root: root)

    assert :ok = Rekindle.Development.Cleanup.startup(project)
    refute File.exists?(Path.join(root, ".rekindle/tmp"))
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop"))
    assert File.dir?(Path.join([root, ".rekindle/dev/web", selected]))

    retained = web_generations(root)
    assert MapSet.member?(retained, selected)
    assert MapSet.size(retained) == 2
    refute MapSet.member?(retained, first) and MapSet.member?(retained, second)
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
    {:ok, manifest} = Rekindle.Web.Manifest.create(temporary, "app.js")
    File.write!(Path.join(temporary, "manifest.json"), Jason.encode!(manifest))

    generation = manifest["generation"]
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
        :gpui
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
    |> Development.call(options)
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
