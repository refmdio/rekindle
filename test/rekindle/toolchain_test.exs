defmodule Rekindle.ToolchainTest do
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain

  test "accepts only the qualified desktop target" do
    root = tmp_dir()
    supported = fake_rustc(root, Toolchain.desktop_target())
    unsupported = fake_rustc(root, "aarch64-unknown-linux-gnu")

    assert {:ok, "x86_64-unknown-linux-gnu"} = Toolchain.target(:desktop, rustc: supported)

    assert {:error, %Toolchain.Error{kind: :unsupported_desktop_target}} =
             Toolchain.target(:desktop, rustc: unsupported)
  end

  test "resolves only the requested version in the user cache" do
    home = tmp_dir()
    environment = %{"XDG_CACHE_HOME" => Path.join(home, "cache"), "HOME" => home}

    first = install_fixture("0.2.125", environment)
    second = install_fixture("0.2.126", environment)

    assert {:ok, ^first} = Toolchain.resolve_wasm_bindgen("0.2.125", env: environment)
    assert {:ok, ^second} = Toolchain.resolve_wasm_bindgen("0.2.126", env: environment)
    assert first != second
  end

  test "does not search global executable directories" do
    home = tmp_dir()

    environment = %{
      "HOME" => home,
      "PATH" => Path.dirname(install_fixture("9.9.9", %{"HOME" => home}))
    }

    assert {:error, %Toolchain.Error{kind: :missing_wasm_bindgen}} =
             Toolchain.resolve_wasm_bindgen("0.2.126", env: environment)
  end

  test "rejects a mismatched cached executable" do
    environment = %{"HOME" => tmp_dir()}
    path = Toolchain.wasm_bindgen_path("0.2.126", environment)
    write_executable(path, "#!/bin/sh\necho 'wasm-bindgen 0.2.125'\n")

    assert {:error, %Toolchain.Error{kind: :version_mismatch}} =
             Toolchain.resolve_wasm_bindgen("0.2.126", env: environment)
  end

  test "installs through Cargo into the exact version root" do
    home = tmp_dir()
    environment = %{"XDG_CACHE_HOME" => Path.join(home, "cache"), "HOME" => home}
    cargo = fake_cargo(home, :success)

    assert {:ok, path} =
             Toolchain.install_wasm_bindgen("0.2.126",
               env: environment,
               cargo: cargo,
               cd: home
             )

    assert path == Toolchain.wasm_bindgen_path("0.2.126", environment)
    assert File.regular?(path)
    assert File.read!(Path.join(home, "cargo-arguments")) =~ "--version =0.2.126"

    assert File.read!(Path.join(home, "cargo-arguments")) =~
             "--root #{Path.dirname(Path.dirname(path))}"
  end

  test "reports installation failure without using another location" do
    home = tmp_dir()
    environment = %{"HOME" => home}

    assert {:error, %Toolchain.Error{kind: :install_failed}} =
             Toolchain.install_wasm_bindgen("0.2.126",
               env: environment,
               cargo: fake_cargo(home, :failure),
               cd: home
             )

    refute File.exists?(Toolchain.wasm_bindgen_path("0.2.126", environment))
  end

  defp install_fixture(version, environment) do
    path = Toolchain.wasm_bindgen_path(version, environment)
    write_executable(path, "#!/bin/sh\necho 'wasm-bindgen #{version}'\n")
    path
  end

  defp fake_cargo(root, result) do
    path = Path.join(root, "cargo")

    body =
      case result do
        :success ->
          """
          printf '%s' "$*" > "#{Path.join(root, "cargo-arguments")}"
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--root" ]; then
              install_root="$2"
              break
            fi
            shift
          done
          mkdir -p "$install_root/bin"
          printf '#!/bin/sh\\necho \"wasm-bindgen 0.2.126\"\\n' > "$install_root/bin/wasm-bindgen"
          chmod +x "$install_root/bin/wasm-bindgen"
          """

        :failure ->
          "exit 23"
      end

    write_executable(path, "#!/bin/sh\n#{body}")
    path
  end

  defp write_executable(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp fake_rustc(root, target) do
    path = Path.join(root, "rustc-#{target}")
    write_executable(path, "#!/bin/sh\nprintf 'rustc 1.90.0\\nhost: #{target}\\n'\n")
    path
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-toolchain-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
