defmodule Rekindle.ToolingIntegrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Rekindle.{Doctor, Setup, Toolchain}

  setup do
    root = tmp_dir()
    File.cp_r!("test/fixtures/cargo_project", Path.join(root, "client"))
    generate_lockfile(root)

    previous = Application.get_env(:rekindle_tooling_test, Rekindle)

    Application.put_env(:rekindle_tooling_test, Rekindle,
      integration: :gpui,
      targets: [web: [], desktop: []]
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:rekindle_tooling_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_tooling_test, Rekindle)
      end
    end)

    environment = %{
      "HOME" => Path.join(root, "home"),
      "XDG_CACHE_HOME" => Path.join(root, "cache")
    }

    rustup = fake_rustup(root, ["x86_64-unknown-linux-gnu"])
    cargo = fake_cargo(root, :install)

    options = [
      project_root: root,
      cd: root,
      env: environment,
      cargo: cargo,
      rustup: rustup
    ]

    %{root: root, environment: environment, options: options}
  end

  test "setup installs missing enabled prerequisites and is idempotent", context do
    assert {:ok, first} = Setup.run(:rekindle_tooling_test, :enabled, context.options)
    assert changed?(first, :rust_web)
    assert changed?(first, :wasm_bindgen)

    assert {:ok, second} = Setup.run(:rekindle_tooling_test, :enabled, context.options)
    refute Enum.any?(second, &(&1.status == :changed))

    assert {:ok, path} =
             Toolchain.resolve_wasm_bindgen("0.2.126", env: context.environment, cd: context.root)

    assert path =~ "/cache/rekindle/tools/wasm-bindgen/0.2.126/"
  end

  test "desktop selection does not install Web tooling", context do
    assert {:ok, checks} = Setup.run(:rekindle_tooling_test, :desktop, context.options)
    refute Enum.any?(checks, &(&1.name == :wasm_bindgen))

    refute File.exists?(Toolchain.wasm_bindgen_path("0.2.126", context.environment))
  end

  test "setup reports missing executables and failed installation", context do
    assert {:error, checks} =
             Setup.run(
               :rekindle_tooling_test,
               :enabled,
               Keyword.put(context.options, :cargo, Path.join(context.root, "missing-cargo"))
             )

    assert error?(checks, :cargo)

    failed_options =
      context.options
      |> Keyword.put(:cargo, fake_cargo(context.root, :fail_install))

    assert {:error, checks} = Setup.run(:rekindle_tooling_test, :web, failed_options)
    assert error?(checks, :wasm_bindgen)
  end

  test "Doctor checks a healthy project without mutating it", context do
    assert {:ok, _checks} = Setup.run(:rekindle_tooling_test, :enabled, context.options)
    before = snapshot(context.root)

    assert {:ok, checks} = Doctor.run(:rekindle_tooling_test, context.options)
    assert Enum.all?(checks, &(&1.status == :ok))
    assert Enum.any?(checks, &(&1.name == :web_integration))
    assert Enum.any?(checks, &(&1.name == :desktop_binary))

    refute Enum.any?(
             checks,
             &String.match?(&1.message, ~r/browser|gpu adapter|graphics driver|runtime adapter/i)
           )

    assert snapshot(context.root) == before
  end

  test "Doctor reports malformed configuration and missing prerequisites", context do
    Application.put_env(:rekindle_tooling_test, Rekindle,
      integration: :unknown,
      targets: [web: []]
    )

    assert {:error, [check]} = Doctor.run(:rekindle_tooling_test, context.options)
    assert check.name == :configuration
    assert check.status == :error
  end

  test "Doctor reports every missing prerequisite without changing the project", context do
    missing_cargo =
      Keyword.put(context.options, :cargo, Path.join(context.root, "missing-cargo"))

    before = snapshot(context.root)
    assert {:error, checks} = Doctor.run(:rekindle_tooling_test, missing_cargo)
    assert error?(checks, :cargo)
    assert error?(checks, :cargo_metadata)
    assert check!(checks, :cargo).message =~ "executable was not found"
    assert snapshot(context.root) == before

    rustup = fake_rustup(context.root, [])
    options = Keyword.put(context.options, :rustup, rustup)
    before = snapshot(context.root)

    assert {:error, checks} = Doctor.run(:rekindle_tooling_test, options)
    assert error?(checks, :rust_web)
    assert error?(checks, :rust_desktop)
    assert error?(checks, :wasm_bindgen)
    assert check!(checks, :rust_web).message =~ "mix rekindle.setup web"
    assert check!(checks, :wasm_bindgen).message =~ "mix rekindle.setup web"
    assert snapshot(context.root) == before
  end

  test "setup rejects commands that succeed without installing their result", context do
    rustup = fake_rustup(context.root, ["x86_64-unknown-linux-gnu"], add?: false)
    options = Keyword.put(context.options, :rustup, rustup)

    assert {:error, checks} = Setup.run(:rekindle_tooling_test, :web, options)
    assert error?(checks, :rust_web)
    assert check!(checks, :rust_web).message =~ "still missing"

    cargo = fake_cargo(context.root, :no_install)

    rustup =
      fake_rustup(context.root, [
        "wasm32-unknown-unknown",
        "x86_64-unknown-linux-gnu"
      ])

    options =
      context.options
      |> Keyword.put(:cargo, cargo)
      |> Keyword.put(:rustup, rustup)

    assert {:error, checks} = Setup.run(:rekindle_tooling_test, :web, options)
    assert error?(checks, :wasm_bindgen)
    assert check!(checks, :wasm_bindgen).message =~ "version check failed"
  end

  test "Doctor rejects output paths that are not real writable directories", context do
    Application.put_env(:rekindle_tooling_test, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    output = Path.join(context.root, "dist/rekindle")
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, "not a directory")

    assert {:error, checks} = Doctor.run(:rekindle_tooling_test, context.options)
    assert error?(checks, :desktop_output)

    File.rm_rf!(Path.dirname(output))
    File.write!(Path.dirname(output), "not a directory")

    assert {:error, checks} = Doctor.run(:rekindle_tooling_test, context.options)
    assert error?(checks, :desktop_output)

    File.rm!(Path.dirname(output))
    destination = Path.join(context.root, "actual-output")
    File.mkdir_p!(destination)
    File.mkdir_p!(Path.dirname(output))
    File.ln_s!(destination, output)

    assert {:error, checks} = Doctor.run(:rekindle_tooling_test, context.options)
    assert error?(checks, :desktop_output)
  end

  test "Doctor checks search permission for the effective user", context do
    Application.put_env(:rekindle_tooling_test, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    state = Path.join(context.root, ".rekindle")
    File.mkdir_p!(state)
    File.chmod!(state, 0o601)
    on_exit(fn -> File.chmod(state, 0o700) end)

    assert {:error, checks} = Doctor.run(:rekindle_tooling_test, context.options)
    assert error?(checks, :state)
  end

  test "Mix tasks report success and return nonzero on diagnosis failure", context do
    previous = Application.get_env(:rekindle, Rekindle)
    previous_path = System.get_env("PATH")
    previous_home = System.get_env("HOME")
    previous_cache = System.get_env("XDG_CACHE_HOME")

    on_exit(fn ->
      restore_application_env(:rekindle, previous)
      restore_system_env("PATH", previous_path)
      restore_system_env("HOME", previous_home)
      restore_system_env("XDG_CACHE_HOME", previous_cache)
    end)

    Application.put_env(:rekindle, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    System.put_env("PATH", context.root <> ":" <> (previous_path || ""))
    System.put_env("HOME", context.environment["HOME"])
    System.put_env("XDG_CACHE_HOME", context.environment["XDG_CACHE_HOME"])

    File.cd!(context.root, fn ->
      Mix.Task.reenable("rekindle.setup")
      assert capture_io(fn -> Mix.Tasks.Rekindle.Setup.run(["desktop"]) end) =~ "[ok]"

      Mix.Task.reenable("rekindle.doctor")
      assert capture_io(fn -> Mix.Tasks.Rekindle.Doctor.run([]) end) =~ "Cargo metadata is valid"

      Application.put_env(:rekindle, Rekindle,
        integration: :invalid,
        targets: [desktop: []]
      )

      Mix.Task.reenable("rekindle.doctor")

      assert_raise Mix.Error, "Rekindle Doctor found errors", fn ->
        capture_io(fn -> Mix.Tasks.Rekindle.Doctor.run([]) end)
      end
    end)
  end

  defp changed?(checks, name),
    do: Enum.any?(checks, &(&1.name == name and &1.status == :changed))

  defp error?(checks, name),
    do: Enum.any?(checks, &(&1.name == name and &1.status == :error))

  defp check!(checks, name), do: Enum.find(checks, &(&1.name == name))

  defp generate_lockfile(root) do
    {_output, 0} =
      System.cmd(
        System.find_executable("cargo"),
        ["generate-lockfile", "--manifest-path", Path.join(root, "client/Cargo.toml")],
        stderr_to_stdout: true
      )
  end

  defp fake_rustup(root, installed, options \\ []) do
    state = Path.join(root, "rust-targets")
    File.write!(state, Enum.join(installed, "\n") <> "\n")
    path = Path.join(root, "rustup")
    add = if Keyword.get(options, :add?, true), do: "echo \"$3\" >> \"#{state}\"", else: ":"

    write_executable(
      path,
      """
      #!/bin/sh
      if [ "$1 $2 $3" = "target list --installed" ]; then
        cat "#{state}"
        exit 0
      fi
      if [ "$1 $2" = "target add" ]; then
        #{add}
        exit 0
      fi
      exit 2
      """
    )

    path
  end

  defp fake_cargo(root, install_result) do
    real_cargo = System.find_executable("cargo")
    path = Path.join(root, "cargo")

    install =
      case install_result do
        :install ->
          """
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--root" ]; then
              install_root="$2"
              break
            fi
            shift
          done
          mkdir -p "$install_root/bin"
          printf '#!/bin/sh\\necho "wasm-bindgen 0.2.126"\\n' > "$install_root/bin/wasm-bindgen"
          chmod +x "$install_root/bin/wasm-bindgen"
          exit 0
          """

        :fail_install ->
          "exit 17"

        :no_install ->
          "exit 0"
      end

    write_executable(
      path,
      """
      #!/bin/sh
      if [ "$1" = "install" ]; then
        #{install}
      fi
      exec "#{real_cargo}" "$@"
      """
    )

    path
  end

  defp snapshot(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
    |> Enum.sort()
  end

  defp write_executable(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp restore_application_env(app, nil), do: Application.delete_env(app, Rekindle)
  defp restore_application_env(app, value), do: Application.put_env(app, Rekindle, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-tooling-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
