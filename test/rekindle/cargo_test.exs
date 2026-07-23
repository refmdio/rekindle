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
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain.Process

  test "bounds captured output" do
    assert {:ok, result} =
             Process.run("/usr/bin/printf", ["1234567890"], cd: File.cwd!(), output_limit: 4)

    assert result.status == 0
    assert result.output == "1234"
    assert result.truncated?
  end

  test "times out and reaps the child" do
    root = tmp_dir()
    pid_file = Path.join(root, "pid")
    executable = wait_executable(root)

    assert {:error, :timeout} =
             Process.run(executable, [pid_file], cd: File.cwd!(), timeout: 100)

    pid = pid_file |> File.read!() |> String.trim()
    refute File.exists?("/proc/#{pid}")
  end

  test "cancels and closes the child" do
    root = tmp_dir()
    pid_file = Path.join(root, "pid")
    executable = wait_executable(root)
    cancel_ref = make_ref()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:runner, self()})

        Process.run(executable, [pid_file],
          cd: File.cwd!(),
          cancel_ref: cancel_ref
        )
      end)

    assert_receive {:runner, runner}
    assert wait_for_file(pid_file, 50)
    send(runner, {:rekindle_cancel, cancel_ref})
    assert Task.await(task) == {:error, :cancelled}

    pid = pid_file |> File.read!() |> String.trim()
    refute File.exists?("/proc/#{pid}")
  end

  defp wait_executable(root) do
    executable = Path.join(root, "wait")
    File.write!(executable, "#!/bin/sh\necho $$ > \"$1\"\nexec /usr/bin/sleep 30\n")
    File.chmod!(executable, 0o755)
    executable
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
