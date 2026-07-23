defmodule Rekindle.DevelopmentTest do
  use ExUnit.Case, async: false

  alias Rekindle.Build.Result
  alias Rekindle.Development.Builder
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
end
