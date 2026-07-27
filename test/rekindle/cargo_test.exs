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

  test "returns a typed error for malformed Cargo metadata", %{project: project} do
    valid = metadata_value(project)

    malformed = [
      Map.delete(valid, "packages"),
      %{valid | "packages" => %{}},
      %{valid | "packages" => [%{}]},
      put_in(valid, ["packages", Access.at(0), "id"], nil),
      put_in(valid, ["packages", Access.at(0), "name"], 1),
      put_in(valid, ["packages", Access.at(0), "manifest_path"], ""),
      put_in(valid, ["packages", Access.at(0), "dependencies"], nil),
      put_in(valid, ["packages", Access.at(0), "dependencies"], [%{"name" => 1}]),
      put_in(valid, ["packages", Access.at(0), "targets"], "desktop"),
      put_in(valid, ["packages", Access.at(0), "targets", Access.at(0), "name"], nil),
      put_in(valid, ["packages", Access.at(0), "targets", Access.at(0), "kind"], "bin"),
      put_in(valid, ["packages", Access.at(0), "targets", Access.at(0), "src_path"], nil),
      %{valid | "workspace_members" => [1]},
      %{valid | "target_directory" => nil}
    ]

    Enum.each(malformed, fn value ->
      cargo = metadata_cargo(project, value)

      assert {:error, %Cargo.Error{kind: :invalid_metadata}} =
               Cargo.Metadata.load(project, cargo: cargo)
    end)
  end

  test "discovers the native executable from Cargo messages", %{project: project} do
    target = target(:desktop)

    assert {:ok, result} = Cargo.build(project, target, :dev)
    assert result.package == "fixture_ui"
    assert result.binary == "desktop"
    assert {:ok, result.target} == Rekindle.Toolchain.host_target()
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
    assert result.target == "wasm32-unknown-unknown"
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

  test "pins desktop builds to the detected host target", %{project: project} do
    {cargo, arguments_file, _started_file, _metadata_cwd_file, _build_cwd_file} =
      fake_cargo(project, :desktop_artifact)

    assert {:ok, host} = Rekindle.Toolchain.host_target()
    assert {:ok, _result} = Cargo.build(project, target(:desktop), :dev, cargo: cargo)

    arguments = File.read!(arguments_file) |> String.split("\n", trim: true)
    assert Enum.take(arguments, -2) == ["--target", host]
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

  test "maps Cargo build timeout", %{project: project} do
    {cargo, _arguments_file, _started_file, _metadata_cwd_file, _build_cwd_file} =
      fake_cargo(project, :wait)

    assert {:error, %Cargo.Error{kind: :timeout}} =
             Cargo.build(project, target(:desktop), :dev, cargo: cargo, timeout: 100)
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

    artifact_target =
      case mode do
        :mismatched_artifact -> "other"
        :desktop_artifact -> "desktop"
        _ -> "web"
      end

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

  defp metadata_cargo(project, value) do
    path =
      Path.join(
        project.root,
        "metadata-cargo-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.write!(
      path,
      "#!/bin/sh\nprintf '%s\\n' '#{Jason.encode!(value)}'\n"
    )

    File.chmod!(path, 0o755)
    path
  end

  defp metadata_value(project) do
    package = cargo_package(project, "fixture_ui", "fixture_ui 0.1.0")

    %{
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
    }
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

  test "returns typed errors for malformed recognized messages" do
    artifact = %{
      "reason" => "compiler-artifact",
      "package_id" => "fixture_ui 0.1.0",
      "target" => %{"name" => "web", "kind" => ["bin"]},
      "filenames" => ["/tmp/web.wasm"],
      "executable" => nil
    }

    diagnostic = %{
      "reason" => "compiler-message",
      "message" => %{
        "level" => "error",
        "message" => "failed",
        "rendered" => "error: failed",
        "spans" => []
      }
    }

    malformed = [
      put_in(artifact, ["target"], nil),
      put_in(artifact, ["target", "name"], nil),
      put_in(artifact, ["target", "kind"], nil),
      put_in(artifact, ["filenames"], nil),
      put_in(artifact, ["filenames"], [1]),
      put_in(artifact, ["executable"], 1),
      put_in(diagnostic, ["message"], nil),
      put_in(diagnostic, ["message", "spans"], nil),
      put_in(diagnostic, ["message", "level"], nil),
      put_in(diagnostic, ["message", "message"], nil),
      put_in(diagnostic, ["message", "rendered"], 1),
      put_in(diagnostic, ["message", "spans"], [
        %{"is_primary" => true, "file_name" => nil, "line_start" => nil}
      ])
    ]

    Enum.each(malformed, fn message ->
      process = %Process{
        status: 0,
        output: Jason.encode!(message),
        truncated?: false
      }

      assert {:error, %Rekindle.Cargo.Error{kind: :invalid_message}} =
               Messages.decode(process, "fixture_ui 0.1.0", "web", :web)
    end)
  end

  test "continues to ignore unknown JSON and capture non-JSON output" do
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
      output: Jason.encode!(%{"reason" => "build-script-executed"}) <> "\nnote\n" <> artifact,
      truncated?: false
    }

    assert {:ok, "/tmp/web.wasm", [], "note"} =
             Messages.decode(process, "fixture_ui 0.1.0", "web", :web)
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

  test "times out a directly owned command" do
    assert {:error, :timeout} =
             Process.run("/usr/bin/sleep", ["10"], cd: File.cwd!(), timeout: 20)
  end

  test "stops the command when its owning task stops" do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-process-owner-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    started = Path.join(root, "started")
    marker = Path.join(root, "completed")
    command = Path.join(root, "delayed-command")

    File.write!(command, "#!/bin/sh\ntouch '#{started}'\nsleep 0.2\ntouch '#{marker}'\n")
    File.chmod!(command, 0o755)

    task = Task.async(fn -> Process.run(command, [], cd: root) end)
    assert eventually?(fn -> File.exists?(started) end)
    Task.shutdown(task, :brutal_kill)
    Elixir.Process.sleep(250)

    refute File.exists?(marker)
  end

  defp eventually?(function, attempts \\ 50)

  defp eventually?(_function, 0), do: false

  defp eventually?(function, attempts) do
    if function.() do
      true
    else
      Elixir.Process.sleep(10)
      eventually?(function, attempts - 1)
    end
  end
end
