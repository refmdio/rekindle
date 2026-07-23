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

  test "stops the watcher, active build, and desktop process as one supervised runtime" do
    root = temporary_desktop_client()
    tools = fake_blocking_tools(root)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", tools.bin <> ":" <> previous_path)

    Application.put_env(:shutdown_demo, ShutdownDemoWeb.Endpoint, code_reloader: true)

    Application.put_env(:shutdown_demo, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      Application.delete_env(:shutdown_demo, ShutdownDemoWeb.Endpoint)
      Application.delete_env(:shutdown_demo, Rekindle)
      File.rm_rf!(root)
    end)

    options = [
      otp_app: :shutdown_demo,
      endpoint: ShutdownDemoWeb.Endpoint,
      project_root: root
    ]

    supervisor = start_supervised!({Rekindle, options})
    assert_until(fn -> File.exists?(tools.started) end)

    children = Supervisor.which_children(supervisor)
    builder = child_pid(children, Rekindle.Development.Builder)
    watcher = child_pid(children, Rekindle.Development.Watcher)
    file_system = child_pid(children, Rekindle.Development.FileSystem)
    desktop = child_pid(children, Rekindle.Desktop.Development)
    desktop_result = desktop_result(root)

    Rekindle.Desktop.Development.replace(desktop, desktop_result)

    assert_until(fn ->
      Rekindle.Desktop.Development.status(desktop).current != nil
    end)

    %{current: %{pid: daemon}} = Rekindle.Desktop.Development.status(desktop)

    stop_supervised(Rekindle)

    assert_until(fn -> File.exists?(tools.cancelled) end)

    Enum.each([supervisor, builder, watcher, file_system, desktop, daemon], fn pid ->
      refute Process.alive?(pid)
    end)
  end

  defp temporary_client do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-supervisor-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))
    File.write!(Path.join(root, "client/src/bin/web.rs"), "fn main() {}\n")
    root
  end

  defp temporary_desktop_client do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-shutdown-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))
    File.write!(Path.join(root, "client/Cargo.toml"), "[package]\nname = \"client\"\n")
    File.write!(Path.join(root, "client/src/bin/desktop.rs"), "fn main() {}\n")
    root
  end

  defp fake_blocking_tools(root) do
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    cargo = Path.join(bin, "cargo")
    rustc = Path.join(bin, "rustc")
    started = Path.join(root, "build-started")
    cancelled = Path.join(root, "build-cancelled")
    package_id = "client 0.1.0"

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package_id,
            "name" => "client",
            "manifest_path" => Path.join(root, "client/Cargo.toml"),
            "targets" => [
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

    write_executable(
      cargo,
      """
      #!/bin/sh
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      touch '#{started}'
      trap 'touch "#{cancelled}"; exit 0' TERM INT
      while true; do sleep 1; done
      """
    )

    write_executable(
      rustc,
      """
      #!/bin/sh
      printf 'rustc 1.90.0\\nhost: test-target\\n'
      """
    )

    %{bin: bin, started: started, cancelled: cancelled}
  end

  defp desktop_result(root) do
    temporary = Path.join(root, "desktop-generation")
    File.mkdir_p!(temporary)
    artifact = Path.join(temporary, "desktop")
    write_executable(artifact, "#!/bin/sh\nwhile true; do sleep 1; done\n")

    {:ok, manifest} =
      Rekindle.Desktop.Manifest.create(
        temporary,
        "desktop",
        "test-target",
        "client",
        "desktop"
      )

    generation_root =
      Path.join([
        root,
        ".rekindle",
        "dev",
        "desktop",
        "test-target",
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
        rust_target: "test-target"
      }
    }
  end

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
