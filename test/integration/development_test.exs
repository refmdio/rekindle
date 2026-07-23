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
    assert runtime.resp_body =~ "await import(current.entry);"
    refute runtime.resp_body =~ ~s|getContext("webgl2")|
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

  test "does not expose unselected or malformed Web paths", %{root: root} do
    generation = publish_web(root, "export default 'ready';")
    options = Development.init(otp_app: :rekindle_development_test, project_root: root)

    assert request("/__rekindle/web/#{generation}/missing.js", options).status == 404
    assert request("/__rekindle/web/not-a-generation/app.js", options).status == 404

    conn = Plug.Test.conn("GET", "/unrelated") |> Development.call(options)
    refute conn.halted
    refute conn.state == :sent
  end

  test "adopts a ready desktop process and replaces it only after handoff", %{root: root} do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    launcher = start_launcher(root, supervisor)
    first = desktop_result(root, "first", :running)
    second = desktop_result(root, "second", :running)

    DesktopDevelopment.replace(launcher, first)
    assert_receive {DesktopDevelopment, {:ready, ^first}}

    assert %{current: %{pid: first_pid}, candidate: nil} =
             DesktopDevelopment.status(launcher)

    assert Process.alive?(first_pid)
    assert read_marker(root)["generation"] == first.metadata.generation

    DesktopDevelopment.replace(launcher, second)
    assert_until(fn -> DesktopDevelopment.status(launcher).candidate != nil end)
    assert Process.alive?(first_pid)
    assert read_marker(root)["generation"] == first.metadata.generation

    assert_receive {DesktopDevelopment, {:ready, ^second}}
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
    assert_receive {DesktopDevelopment, {:ready, ^first}}
    %{current: %{pid: first_pid}} = DesktopDevelopment.status(launcher)

    DesktopDevelopment.replace(launcher, broken)
    assert_receive {DesktopDevelopment, {:error, %Rekindle.Desktop.Error{kind: :readiness}}}

    assert %{current: %{pid: ^first_pid}, candidate: nil} =
             DesktopDevelopment.status(launcher)

    assert Process.alive?(first_pid)
    assert read_marker(root)["generation"] == first.metadata.generation
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
        :running -> "#!/bin/sh\n# #{name}\nwhile true; do sleep 1; done\n"
        :exit -> "#!/bin/sh\n# #{name}\nexit 0\n"
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
