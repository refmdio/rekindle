defmodule Rekindle.CargoTest do
  use ExUnit.Case, async: true

  alias Rekindle.{Cargo, Config}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-cargo-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    File.cp_r!("test/fixtures/cargo_project", Path.join(root, "client"))
    on_exit(fn -> File.rm_rf!(root) end)

    project = %Config{
      otp_app: :fixture,
      root: root,
      client_root: Path.join(root, "client"),
      integration: :gpui,
      targets: %{},
      public_dir: Path.join(root, "priv/static")
    }

    %{project: project}
  end

  test "loads Cargo metadata and uses its target directory", %{project: project} do
    assert {:ok, metadata} = Cargo.Metadata.load(project)
    assert [%{name: "fixture_ui"}] = metadata.packages
    assert metadata.target_directory == Path.join(project.client_root, "target")
  end

  test "discovers the native executable from Cargo messages", %{project: project} do
    target = target(:desktop)

    assert {:ok, result} = Cargo.build(project, target, :dev)
    assert result.package == "fixture_ui"
    assert result.binary == "desktop"
    assert File.regular?(result.artifact)
    assert Path.basename(result.artifact) == "desktop"
  end

  test "builds through a contained client symbolic link", %{project: project} do
    actual_client = Path.join(project.root, "actual-client")
    File.rename!(project.client_root, actual_client)
    File.ln_s!("actual-client", project.client_root)
    project = %{project | client_root: actual_client}

    assert {:ok, result} = Cargo.build(project, target(:desktop), :dev)
    assert result.binary == "desktop"
    assert File.regular?(result.artifact)
  end

  test "discovers the Web Wasm artifact from Cargo messages", %{project: project} do
    target = target(:web)
    cargo = rustup_path("cargo")
    rustc = rustup_path("rustc")

    assert {:ok, result} =
             Cargo.build(project, target, :release, cargo: cargo, env: [{"RUSTC", rustc}])

    assert result.binary == "web"
    assert String.ends_with?(result.artifact, ".wasm")
    assert File.regular?(result.artifact)
  end

  test "reports Cargo compiler diagnostics", %{project: project} do
    File.write!(Path.join(project.client_root, "src/bin/desktop.rs"), "fn main() { missing(); }")

    assert {:error, %Cargo.Error{kind: :build_failed, diagnostics: diagnostics}} =
             Cargo.build(project, target(:desktop), :dev)

    assert Enum.any?(diagnostics, &(&1.severity == :error and &1.source == :cargo))
  end

  test "requires an unambiguous package selection", %{project: project} do
    target = %{target(:desktop) | package: "missing"}

    assert {:error, %Cargo.Error{kind: :package_not_found}} =
             Cargo.build(project, target, :dev)
  end

  test "passes the configured Cargo selection and build arguments exactly", %{project: project} do
    {cargo, arguments_file, _started_file, metadata_cwd_file, build_cwd_file} =
      fake_cargo(project, :artifact)

    configured = %{
      target(:web)
      | package: "fixture_ui",
        binary: "web",
        features: ["canvas", "logging"],
        profiles: %{dev: "fast", release: "shipping"}
    }

    assert {:ok, result} = Cargo.build(project, configured, :dev, cargo: cargo)
    assert result.artifact == Path.join(project.root, "web.wasm")
    assert File.read!(metadata_cwd_file) == project.client_root <> "\n"
    assert File.read!(build_cwd_file) == project.client_root <> "\n"

    assert File.read!(arguments_file) |> String.split("\n", trim: true) == [
             "build",
             "--manifest-path",
             Path.join(project.client_root, "Cargo.toml"),
             "--message-format=json-render-diagnostics",
             "--package",
             "fixture_ui",
             "--bin",
             "web",
             "--profile",
             "fast",
             "--target",
             "wasm32-unknown-unknown",
             "--features",
             "canvas,logging"
           ]
  end

  test "rejects mismatched Cargo artifacts", %{project: project} do
    {cargo, _arguments_file, _started_file, _metadata_cwd_file, _build_cwd_file} =
      fake_cargo(project, :mismatched_artifact)

    assert {:error, %Cargo.Error{kind: :artifact_not_found}} =
             Cargo.build(project, target(:desktop), :dev, cargo: cargo)
  end

  test "rejects ambiguous packages and binaries", %{project: project} do
    package = cargo_package(project, "fixture_ui", "fixture_ui 0.1.0")
    other = cargo_package(project, "other_ui", "other_ui 0.1.0")

    metadata = %Cargo.Metadata{
      packages: [package, other],
      workspace_members: MapSet.new([package.id, other.id]),
      target_directory: Path.join(project.client_root, "target")
    }

    assert {:error, %Cargo.Error{kind: :ambiguous_package}} =
             Cargo.resolve(metadata, project, target(:desktop))

    duplicate = %{package | targets: package.targets ++ package.targets}
    metadata = %{metadata | packages: [duplicate], workspace_members: MapSet.new([package.id])}

    assert {:error, %Cargo.Error{kind: :ambiguous_binary}} =
             Cargo.resolve(metadata, project, target(:desktop))
  end

  test "maps Cargo build timeout and cancellation", %{project: project} do
    {cargo, _arguments_file, _started_file, _metadata_cwd_file, _build_cwd_file} =
      fake_cargo(project, :wait)

    assert {:error, %Cargo.Error{kind: :timeout}} =
             Cargo.build(project, target(:desktop), :dev, cargo: cargo, timeout: 100)

    {cargo, _arguments_file, started_file, _metadata_cwd_file, _build_cwd_file} =
      fake_cargo(project, :wait)

    cancel_ref = make_ref()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:cargo_runner, self()})

        Cargo.build(project, target(:desktop), :dev,
          cargo: cargo,
          cancel_ref: cancel_ref
        )
      end)

    assert_receive {:cargo_runner, runner}
    assert wait_for_file(started_file, 50)
    send(runner, {:rekindle_cancel, cancel_ref})

    assert {:error, %Cargo.Error{kind: :cancelled}} = Task.await(task)
  end

  defp target(name) do
    %Config.Target{
      name: name,
      entry: "client/src/bin/#{name}.rs",
      package: nil,
      binary: nil,
      features: [],
      profiles: %{dev: "dev", release: "release"}
    }
  end

  defp rustup_path(tool) do
    {path, 0} = System.cmd("rustup", ["which", tool])
    String.trim(path)
  end

  defp fake_cargo(project, mode) do
    path = Path.join(project.root, "fake-cargo-#{mode}")
    arguments_file = path <> ".arguments"
    started_file = path <> ".started"
    metadata_cwd_file = path <> ".metadata-cwd"
    build_cwd_file = path <> ".build-cwd"
    File.rm(arguments_file)
    File.rm(started_file)
    File.rm(metadata_cwd_file)
    File.rm(build_cwd_file)
    package = cargo_package(project, "fixture_ui", "fixture_ui 0.1.0")

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package.id,
            "name" => package.name,
            "manifest_path" => package.manifest_path,
            "targets" => package.targets,
            "dependencies" => [%{"name" => "gpui"}]
          }
        ],
        "workspace_members" => [package.id],
        "target_directory" => Path.join(project.client_root, "target")
      })

    artifact_target = if mode == :mismatched_artifact, do: "other", else: "web"

    artifact =
      Jason.encode!(%{
        "reason" => "compiler-artifact",
        "package_id" => package.id,
        "target" => %{"name" => artifact_target, "kind" => ["bin"]},
        "filenames" => [Path.join(project.root, "web.wasm")],
        "executable" => Path.join(project.root, "desktop")
      })

    build =
      case mode do
        :wait ->
          """
          echo $$ > '#{started_file}'
          exec /usr/bin/sleep 30
          """

        _ ->
          "printf '%s\\n' '#{artifact}'"
      end

    File.write!(
      path,
      """
      #!/bin/sh
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' "$PWD" > '#{metadata_cwd_file}'
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      printf '%s\\n' "$PWD" > '#{build_cwd_file}'
      printf '%s\\n' "$@" > '#{arguments_file}'
      #{build}
      """
    )

    File.chmod!(path, 0o755)
    {path, arguments_file, started_file, metadata_cwd_file, build_cwd_file}
  end

  defp cargo_package(project, name, id) do
    %{
      id: id,
      name: name,
      manifest_path: Path.join(project.client_root, "Cargo.toml"),
      targets: [
        %{
          "name" => "desktop",
          "kind" => ["bin"],
          "src_path" => Path.join(project.client_root, "src/bin/desktop.rs")
        },
        %{
          "name" => "web",
          "kind" => ["bin"],
          "src_path" => Path.join(project.client_root, "src/bin/web.rs")
        }
      ],
      dependencies: ["gpui"]
    }
  end

  defp wait_for_file(_path, 0), do: false

  defp wait_for_file(path, attempts) do
    if File.exists?(path) do
      true
    else
      Process.sleep(10)
      wait_for_file(path, attempts - 1)
    end
  end
end

defmodule Rekindle.Cargo.MessagesTest do
  use ExUnit.Case, async: true

  alias Rekindle.Cargo.Messages
  alias Rekindle.Toolchain.Process

  test "decodes compiler diagnostics and the matching artifact" do
    diagnostic =
      Jason.encode!(%{
        "reason" => "compiler-message",
        "message" => %{
          "level" => "warning",
          "message" => "unused value",
          "rendered" => "warning: unused value",
          "spans" => [
            %{"is_primary" => true, "file_name" => "src/bin/web.rs", "line_start" => 3}
          ]
        }
      })

    artifact =
      Jason.encode!(%{
        "reason" => "compiler-artifact",
        "package_id" => "fixture_ui 0.1.0",
        "target" => %{"name" => "web", "kind" => ["bin"]},
        "filenames" => ["/tmp/web.wasm"],
        "executable" => nil
      })

    process = %Process{
      status: 0,
      output: diagnostic <> "\n" <> artifact <> "\n",
      truncated?: false
    }

    assert {:ok, "/tmp/web.wasm", [warning], ""} =
             Messages.decode(process, "fixture_ui 0.1.0", "web", :web)

    assert warning.severity == :warning
    assert warning.file == "src/bin/web.rs"
    assert warning.line == 3
    assert warning.rendered == "warning: unused value"
  end
end

defmodule Rekindle.Cargo.ProcessTest do
  use ExUnit.Case, async: false

  alias Rekindle.Toolchain.Process

  test "bounds captured output" do
    assert {:ok, result} =
             Process.run("/usr/bin/printf", ["1234567890"], cd: File.cwd!(), output_limit: 4)

    assert result.status == 0
    assert result.output == "1234"
    assert result.truncated?
  end

  test "does not launch when process group control is unavailable" do
    root = tmp_dir()
    bin = Path.join(root, "bin")
    marker = Path.join(root, "started")
    executable = Path.join(root, "mark-started")
    previous_path = System.fetch_env!("PATH")

    File.mkdir_p!(bin)
    File.ln_s!(System.find_executable("setsid"), Path.join(bin, "setsid"))
    File.ln_s!(System.find_executable("kill"), Path.join(bin, "kill"))
    File.write!(executable, "#!/bin/sh\ntouch \"#{marker}\"\n")
    File.chmod!(executable, 0o755)

    on_exit(fn -> System.put_env("PATH", previous_path) end)
    System.put_env("PATH", bin)

    assert {:error, {:start, error}} = Process.run(executable, [], cd: root)
    assert Exception.message(error) == "pkill executable was not found"
    refute File.exists?(marker)
  end

  test "does not launch when process group control is not operational" do
    root = tmp_dir()
    bin = Path.join(root, "bin")
    marker = Path.join(root, "started")
    executable = Path.join(root, "mark-started")
    previous_path = System.fetch_env!("PATH")

    File.mkdir_p!(bin)

    for name <- ["setsid", "pgrep", "kill"] do
      File.ln_s!(System.find_executable(name), Path.join(bin, name))
    end

    File.write!(Path.join(bin, "pkill"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(bin, "pkill"), 0o755)
    File.write!(executable, "#!/bin/sh\ntouch \"#{marker}\"\n")
    File.chmod!(executable, 0o755)

    on_exit(fn -> System.put_env("PATH", previous_path) end)
    System.put_env("PATH", bin)

    assert {:error, {:start, error}} = Process.run(executable, [], cd: root)
    assert Exception.message(error) == "process group controls are not operational"
    refute File.exists?(marker)
  end

  test "falls back to direct group-member cleanup when pkill is a no-op" do
    root = tmp_dir()
    bin = Path.join(root, "bin")
    previous_path = System.fetch_env!("PATH")

    File.mkdir_p!(bin)

    for name <- ["setsid", "kill"] do
      File.ln_s!(System.find_executable(name), Path.join(bin, name))
    end

    File.write!(Path.join(bin, "pkill"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin, "pkill"), 0o755)
    on_exit(fn -> System.put_env("PATH", previous_path) end)
    System.put_env("PATH", bin)

    timeout_parent = Path.join(root, "timeout-parent")
    timeout_child = Path.join(root, "timeout-child")

    assert {:error, :timeout} =
             Process.run(wait_executable(root), [timeout_parent, timeout_child],
               cd: root,
               timeout: 100
             )

    refute_process(timeout_parent)
    refute_process(timeout_child)

    cancel_parent = Path.join(root, "cancel-parent")
    cancel_child = Path.join(root, "cancel-child")
    cancel_ref = make_ref()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:no_op_runner, self()})

        Process.run(wait_executable(root), [cancel_parent, cancel_child],
          cd: root,
          cancel_ref: cancel_ref
        )
      end)

    assert_receive {:no_op_runner, runner}
    assert wait_for_file(cancel_child, 50)
    send(runner, {:rekindle_cancel, cancel_ref})
    assert Task.await(task) == {:error, :cancelled}
    refute_process(cancel_parent)
    refute_process(cancel_child)
  end

  test "times out and reaps the child" do
    root = tmp_dir()
    parent_pid_file = Path.join(root, "parent-pid")
    child_pid_file = Path.join(root, "child-pid")
    executable = wait_executable(root)

    assert {:error, :timeout} =
             Process.run(executable, [parent_pid_file, child_pid_file],
               cd: File.cwd!(),
               timeout: 100
             )

    refute_process(parent_pid_file)
    refute_process(child_pid_file)
  end

  test "cancels and closes the child" do
    root = tmp_dir()
    parent_pid_file = Path.join(root, "parent-pid")
    child_pid_file = Path.join(root, "child-pid")
    executable = wait_executable(root)
    cancel_ref = make_ref()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:runner, self()})

        Process.run(executable, [parent_pid_file, child_pid_file],
          cd: File.cwd!(),
          cancel_ref: cancel_ref
        )
      end)

    assert_receive {:runner, runner}
    assert wait_for_file(child_pid_file, 50)
    send(runner, {:rekindle_cancel, cancel_ref})
    assert Task.await(task) == {:error, :cancelled}

    refute_process(parent_pid_file)
    refute_process(child_pid_file)
  end

  defp wait_executable(root) do
    child = Path.join(root, "ignore-term")

    File.write!(
      child,
      "#!/bin/sh\nprintf 'rekindle) child\\n' > /proc/self/comm\ntrap '' TERM\nwhile :; do /usr/bin/sleep 30; done\n"
    )

    File.chmod!(child, 0o755)
    executable = Path.join(root, "wait")

    File.write!(
      executable,
      "#!/bin/sh\necho $$ > \"$1\"\n\"#{child}\" &\necho $! > \"$2\"\nwait\n"
    )

    File.chmod!(executable, 0o755)
    executable
  end

  defp refute_process(pid_file) do
    pid = pid_file |> File.read!() |> String.trim()
    refute wait_for_process_exit(pid, 50), "process #{pid} survived"
  end

  defp wait_for_process_exit(_pid, 0), do: true

  defp wait_for_process_exit(pid, attempts) do
    if File.exists?("/proc/#{pid}") do
      :timer.sleep(10)
      wait_for_process_exit(pid, attempts - 1)
    else
      false
    end
  end

  defp wait_for_file(_path, 0), do: false

  defp wait_for_file(path, attempts) do
    if File.exists?(path) do
      true
    else
      :timer.sleep(10)
      wait_for_file(path, attempts - 1)
    end
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-process-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
