defmodule RekindleTest do
  use ExUnit.Case, async: false

  test "is a valid supervision child" do
    root = temporary_client()
    options = [otp_app: :demo, endpoint: DemoWeb.Endpoint, project_root: root]

    assert %{start: {Rekindle, :start_link, [^options]}} =
             Supervisor.child_spec({Rekindle, options}, [])

    Application.put_env(:demo, DemoWeb.Endpoint, code_reloader: true)
    Application.put_env(:demo, Rekindle, integration: :gpui, targets: [web: []])

    on_exit(fn ->
      Application.delete_env(:demo, DemoWeb.Endpoint)
      Application.delete_env(:demo, Rekindle)
      File.rm_rf!(root)
    end)

    assert {:ok, pid} = start_supervised({Rekindle, options})
    assert Process.alive?(pid)
    assert length(Supervisor.which_children(pid)) == 3
  end

  test "does not start outside code-reloading environments" do
    Application.put_env(:production_demo, Unrelated, code_reloader: true)
    on_exit(fn -> Application.delete_env(:production_demo, Unrelated) end)

    assert :ignore =
             Rekindle.start_link(
               otp_app: :production_demo,
               endpoint: ProductionDemoWeb.Endpoint
             )
  end

  @tag timeout: 30_000
  test "stops queued Web and desktop work as one supervised runtime" do
    root = temporary_combined_client()
    tools = fake_blocking_tools(root)
    previous_path = System.get_env("PATH")
    previous_cache = System.get_env("XDG_CACHE_HOME")
    System.put_env("PATH", tools.bin <> ":" <> previous_path)
    System.put_env("XDG_CACHE_HOME", tools.cache)

    Application.put_env(:shutdown_demo, ShutdownDemoWeb.Endpoint, code_reloader: true)

    Application.put_env(:shutdown_demo, Rekindle,
      integration: :gpui,
      targets: [web: [], desktop: []]
    )

    on_exit(fn ->
      restore_environment("PATH", previous_path)
      restore_environment("XDG_CACHE_HOME", previous_cache)
      Application.delete_env(:shutdown_demo, ShutdownDemoWeb.Endpoint)
      Application.delete_env(:shutdown_demo, Rekindle)
      File.rm_rf!(root)
    end)

    selected = publish_web_generation(root)
    selector = Path.join(root, ".rekindle/dev/web-current.json")
    selected_contents = File.read!(selector)
    owner = self()
    observer = Task.async(fn -> observe_web_selection(owner, root, nil) end)
    on_exit(fn -> if Process.alive?(observer.pid), do: send(observer.pid, :stop) end)
    assert_receive {:browser_ready, ^selected}, 1_000

    options = [
      otp_app: :shutdown_demo,
      endpoint: ShutdownDemoWeb.Endpoint,
      project_root: root
    ]

    supervisor = start_supervised!({Rekindle, options})
    assert_until(fn -> File.exists?(tools.cargo_started) end)
    assert_until(fn -> File.exists?(tools.bindgen_started) end)

    children = Supervisor.which_children(supervisor)
    builder = child_pid(children, Rekindle.Development.Builder)
    watcher = child_pid(children, Rekindle.Development.Watcher)
    file_system = child_pid(children, Rekindle.Development.FileSystem)
    desktop_supervisor = child_pid(children, Rekindle.Desktop.Processes)
    desktop = child_pid(children, Rekindle.Desktop.Development)
    desktop_result = desktop_result(root, tools.desktop_launched)

    Rekindle.Desktop.Development.replace(desktop, desktop_result)

    assert_until(fn ->
      Rekindle.Desktop.Development.status(desktop).current != nil
    end)

    %{current: %{pid: daemon}} = Rekindle.Desktop.Development.status(desktop)

    Rekindle.Development.Builder.rebuild(builder, :all)

    assert_until(fn ->
      match?(
        %{
          web: %{building?: true, pending?: true},
          desktop: %{building?: true, pending?: true}
        },
        Rekindle.Development.Builder.status(builder)
      )
    end)

    stop_supervised(Rekindle)

    Enum.each(
      [supervisor, builder, watcher, file_system, desktop_supervisor, desktop, daemon],
      fn pid ->
        refute Process.alive?(pid)
      end
    )

    Process.sleep(300)

    assert File.read!(selector) == selected_contents
    assert selected_web_generations(root) == [selected]

    assert tools.desktop_launched |> File.read!() |> String.split("\n", trim: true) == [
             "started"
           ]

    refute_receive {:browser_reload, _generation}, 100
    refute_receive {:browser_error, _status}, 100
    send(observer.pid, :stop)
    assert :ok = Task.await(observer)
  end

  defp observe_web_selection(owner, root, previous) do
    receive do
      :stop ->
        :ok
    after
      20 ->
        previous =
          case current_web_generation(root) do
            {:ok, generation} when is_nil(previous) ->
              send(owner, {:browser_ready, generation})
              generation

            {:ok, generation} when generation != previous ->
              send(owner, {:browser_reload, generation})
              generation

            {:ok, _generation} ->
              previous

            {:error, status} ->
              send(owner, {:browser_error, status})
              previous
          end

        observe_web_selection(owner, root, previous)
    end
  end

  defp current_web_generation(root) do
    conn =
      Plug.Test.conn("GET", "/__rekindle/current")
      |> Rekindle.Phoenix.Development.call(
        otp_app: :shutdown_demo,
        project_root: root
      )

    case conn.status do
      200 -> {:ok, conn.resp_body |> Jason.decode!() |> Map.fetch!("generation")}
      status -> {:error, status}
    end
  end

  defp temporary_client do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-supervisor-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))

    File.write!(Path.join(root, "client/Cargo.toml"), """
    [package]
    name = "client"
    version = "0.1.0"
    edition = "2024"
    """)

    File.write!(Path.join(root, "client/src/bin/web.rs"), "fn main() {}\n")
    root
  end

  defp temporary_combined_client do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-shutdown-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))

    File.write!(
      Path.join(root, "client/Cargo.toml"),
      "[package]\nname = \"client\"\nversion = \"0.1.0\"\nedition = \"2024\"\n"
    )

    File.write!(Path.join(root, "client/src/bin/web.rs"), "fn main() {}\n")
    File.write!(Path.join(root, "client/src/bin/desktop.rs"), "fn main() {}\n")
    root
  end

  defp fake_blocking_tools(root) do
    bin = Path.join(root, "bin")
    cache = Path.join(root, "cache")
    File.mkdir_p!(bin)
    cargo = Path.join(bin, "cargo")
    rustc = Path.join(bin, "rustc")

    wasm_bindgen =
      Path.join([
        cache,
        "rekindle",
        "tools",
        "wasm-bindgen",
        Rekindle.Toolchain.wasm_bindgen_version(),
        "bin",
        "wasm-bindgen"
      ])

    File.mkdir_p!(Path.dirname(wasm_bindgen))

    cargo_started = Path.join(root, "cargo-started")
    bindgen_started = Path.join(root, "bindgen-started")
    package_id = "client 0.1.0"
    web_artifact = Path.join(root, "client/target/wasm32-unknown-unknown/debug/web.wasm")

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package_id,
            "name" => "client",
            "manifest_path" => Path.join(root, "client/Cargo.toml"),
            "targets" => [
              %{
                "name" => "web",
                "kind" => ["bin"],
                "src_path" => Path.join(root, "client/src/bin/web.rs")
              },
              %{
                "name" => "desktop",
                "kind" => ["bin"],
                "src_path" => Path.join(root, "client/src/bin/desktop.rs")
              }
            ],
            "dependencies" => [%{"name" => "gpui"}]
          }
        ],
        "workspace_members" => [package_id],
        "target_directory" => Path.join(root, "client/target")
      })

    compiler_artifact =
      Jason.encode!(%{
        "reason" => "compiler-artifact",
        "package_id" => package_id,
        "target" => %{"name" => "web", "kind" => ["bin"]},
        "filenames" => [web_artifact],
        "executable" => nil
      })

    write_executable(
      cargo,
      """
      #!/bin/sh
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      binary=""
      previous=""
      for argument in "$@"; do
        if [ "$previous" = "--bin" ]; then binary="$argument"; fi
        previous="$argument"
      done
      if [ "$binary" = "web" ]; then
        mkdir -p '#{Path.dirname(web_artifact)}'
        printf 'wasm' > '#{web_artifact}'
        printf '%s\\n' '#{compiler_artifact}'
        exit 0
      fi
      touch '#{cargo_started}'
      exec /usr/bin/sleep 300
      """
    )

    write_executable(
      rustc,
      """
      #!/bin/sh
      printf 'rustc 1.90.0\\nhost: x86_64-unknown-linux-gnu\\n'
      """
    )

    write_executable(
      wasm_bindgen,
      """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo "wasm-bindgen #{Rekindle.Toolchain.wasm_bindgen_version()}"
        exit 0
      fi
      touch '#{bindgen_started}'
      exec /usr/bin/sleep 300
      """
    )

    %{
      bin: bin,
      cache: cache,
      cargo_started: cargo_started,
      bindgen_started: bindgen_started,
      desktop_launched: Path.join(root, "desktop-launched")
    }
  end

  defp desktop_result(root, launched) do
    target = host_target!()
    temporary = Path.join(root, "desktop-generation")
    File.mkdir_p!(temporary)
    artifact = Path.join(temporary, "desktop")

    write_executable(
      artifact,
      """
      #!/bin/sh
      echo started >> '#{launched}'
      while true; do sleep 1; done
      """
    )

    {:ok, manifest} =
      Rekindle.Desktop.Manifest.create(
        temporary,
        "desktop",
        target,
        "client",
        "desktop",
        :gpui
      )

    generation_root =
      Path.join([
        root,
        ".rekindle",
        "dev",
        "desktop",
        target,
        manifest["generation"]
      ])

    File.mkdir_p!(Path.dirname(generation_root))
    File.rename!(temporary, generation_root)
    manifest_path = Path.join(generation_root, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    %Rekindle.Build.Result{
      target: :desktop,
      profile: :dev,
      artifact: Path.join(generation_root, "desktop"),
      metadata: %{
        generation: manifest["generation"],
        manifest: manifest_path,
        rust_target: target
      }
    }
  end

  defp host_target! do
    {:ok, target} = Rekindle.Toolchain.host_target()
    target
  end

  defp publish_web_generation(root) do
    source = Path.join(root, "web-baseline")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "app.js"), "export default async function initialize() {}")
    {:ok, manifest} = Rekindle.Web.Manifest.create(source, "app.js")
    generation = manifest["generation"]
    destination = Path.join([root, ".rekindle", "dev", "web", generation])
    File.mkdir_p!(destination)
    File.cp!(Path.join(source, "app.js"), Path.join(destination, "app.js"))
    File.write!(Path.join(destination, "manifest.json"), Jason.encode!(manifest))
    File.mkdir_p!(Path.join(root, ".rekindle/dev"))

    File.write!(
      Path.join(root, ".rekindle/dev/web-current.json"),
      Jason.encode!(%{"generation" => generation})
    )

    generation
  end

  defp selected_web_generations(root) do
    root
    |> Path.join(".rekindle/dev/web/*")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  defp restore_environment(name, nil), do: System.delete_env(name)
  defp restore_environment(name, value), do: System.put_env(name, value)

  defp child_pid(children, id) do
    case List.keyfind(children, id, 0) do
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> flunk("missing supervised child #{inspect(id)}")
    end
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp assert_until(fun, attempts \\ 100)

  defp assert_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_until(fun, attempts - 1)
    end
  end

  defp assert_until(_fun, 0), do: flunk("condition did not become true")
end
