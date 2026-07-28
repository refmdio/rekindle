defmodule Rekindle.ToolchainTest do
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain

  test "resolves Cargo through rustup in the client directory" do
    root = tmp_dir()
    client = Path.join(root, "client")
    cargo = Path.join(root, "toolchains/nightly/bin/cargo")
    rustc = Path.join(root, "toolchains/nightly/bin/rustc")
    rustup = Path.join(root, "bin/rustup")
    trace = Path.join(root, "rustup-cwd")

    File.mkdir_p!(client)
    File.write!(Path.join(client, "rust-toolchain.toml"), "[toolchain]\nchannel = \"nightly\"\n")
    write_executable(cargo, "#!/bin/sh\necho 'cargo 1.99.0-nightly'\n")
    write_executable(rustc, "#!/bin/sh\necho 'rustc 1.99.0-nightly'\n")

    write_executable(
      rustup,
      """
      printf '%s' "$PWD" > "#{trace}"
      if [ "$1" = "which" ] && [ "$2" = "cargo" ]; then
        printf '%s\\n' "#{cargo}"
        exit 0
      fi
      if [ "$1" = "which" ] && [ "$2" = "rustc" ]; then
        printf '%s\\n' "#{rustc}"
        exit 0
      fi
      exit 1
      """
    )

    assert Toolchain.cargo_path(rustup: rustup, cd: client) == cargo
    assert File.read!(trace) == client
    assert {:ok, "1.99.0-nightly"} = Toolchain.cargo_version(rustup: rustup, cd: client)

    environment = Toolchain.cargo_environment(rustup: rustup, cd: client) |> Map.new()
    assert environment["RUSTC"] == rustc
    assert environment["PATH"] |> String.split(":") |> hd() == Path.dirname(cargo)
  end

  test "an explicit Cargo executable takes precedence over rustup" do
    root = tmp_dir()
    cargo = Path.join(root, "cargo")
    write_executable(cargo, "#!/bin/sh\necho 'cargo 1.90.0'\n")

    assert Toolchain.cargo_path(cargo: cargo, rustup: Path.join(root, "missing")) == cargo
  end

  test "does not fall back to a system Cargo when the project toolchain is unavailable" do
    root = tmp_dir()
    client = Path.join(root, "client")
    rustup = Path.join(root, "bin/rustup")

    File.mkdir_p!(client)
    File.write!(Path.join(client, "rust-toolchain.toml"), "[toolchain]\nchannel = \"nightly\"\n")
    write_executable(rustup, "#!/bin/sh\nexit 1\n")

    expected = Path.join(Path.dirname(rustup), "cargo")
    assert Toolchain.cargo_path(rustup: rustup, cd: client) == expected

    assert {:error, %Toolchain.Error{kind: :missing_cargo}} =
             Toolchain.cargo_version(rustup: rustup, cd: client)
  end

  test "preserves an explicitly configured Rust compiler" do
    root = tmp_dir()
    rustc = Path.join(root, "rustc")
    write_executable(rustc, "#!/bin/sh\nexit 0\n")

    assert Toolchain.cargo_environment(rustc: rustc, env: [{"RUSTFLAGS", "-Dwarnings"}])
           |> Map.new() == %{"RUSTC" => rustc, "RUSTFLAGS" => "-Dwarnings"}

    assert Toolchain.cargo_environment(
             rustc: Path.join(root, "selected"),
             env: [{"RUSTC", rustc}]
           )
           |> Map.new() == %{"RUSTC" => Path.join(root, "selected")}
  end

  test "uses the rustc host target for desktop builds" do
    root = tmp_dir()
    x86 = fake_rustc(root, "x86_64-unknown-linux-gnu")
    arm = fake_rustc(root, "aarch64-unknown-linux-gnu")

    assert {:ok, "x86_64-unknown-linux-gnu"} = Toolchain.target(:desktop, rustc: x86)
    assert {:ok, "aarch64-unknown-linux-gnu"} = Toolchain.target(:desktop, rustc: arm)
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
