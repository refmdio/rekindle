defmodule Rekindle.CargoBackendIntegrationTest do
  use ExUnit.Case, async: false

  alias Rekindle.BuildGraph.Identity
  alias Rekindle.Cargo
  alias Rekindle.Config.{DesktopTarget, EnvironmentPolicy, ProcessPolicy, WebTarget}
  alias Rekindle.{ProcessRunner, Scheduler}

  @digest String.duplicate("a", 64)

  setup_all do
    target = Path.expand("_build/test/rekindle-toolchain")
    cargo = System.find_executable("cargo") || raise "cargo is required"

    assert {_output, 0} =
             System.cmd(
               cargo,
               [
                 "build",
                 "--release",
                 "--locked",
                 "--manifest-path",
                 Path.expand("crates/rekindle-toolchain/Cargo.toml")
               ],
               env: [{"CARGO_TARGET_DIR", target}],
               stderr_to_stdout: true
             )

    helper = Path.join(target, "release/rekindle_toolchain")
    assert File.regular?(helper)
    %{helper: helper}
  end

  setup %{helper: helper} do
    root = temp_root("workspace")
    client_root = Path.join(root, "client")
    target_directory = Path.join(root, "cargo-target")

    File.mkdir_p!(root)
    File.cp_r!(Path.expand("test/fixtures/cargo_backend"), client_root)
    File.mkdir_p!(target_directory)
    on_exit(fn -> File.rm_rf!(root) end)

    runner = start_supervised!(ProcessRunner)

    cargo =
      start_supervised!(
        {Cargo, runner: runner, helper: helper, authority_owner: self(), max_cargo_builds: 2}
      )

    %{
      cargo: cargo,
      runner: runner,
      client_root: client_root,
      project_root: root,
      target_directory: target_directory
    }
  end

  test "one Cargo facade discovers and builds real Web and desktop targets", context do
    web = execute_target(context, :web)
    desktop = execute_target(context, :desktop)

    assert Path.extname(web.artifact.path) == ".wasm"
    assert File.regular?(web.artifact.path)
    assert web.artifact.size > 0

    assert File.regular?(desktop.artifact.path)
    assert Bitwise.band(desktop.artifact.mode, 0o100) != 0
    assert desktop.artifact.size > 0
    refute desktop.artifact.path == web.artifact.path
  end

  test "an unqualified toolchain cannot start Cargo", context do
    config = %{
      config(:web)
      | toolchain: %{
          kind: :path,
          cargo: "/missing/cargo",
          rustc: "/missing/rustc",
          identity: "missing"
        }
    }

    {identity, scheduler} = authority_input(:web)
    assert {:ok, authority} = Cargo.authorize(context.cargo, identity, scheduler)

    assert {:error, %{code: :tool_missing}} =
             Cargo.metadata(
               context.cargo,
               options(context, :web, config, authority)
             )

    assert :sys.get_state(context.runner).jobs == %{}
  end

  defp execute_target(context, target) do
    config = config(target)
    {identity, scheduler} = authority_input(target)
    assert {:ok, authority} = Cargo.authorize(context.cargo, identity, scheduler)
    options = options(context, target, config, authority)

    assert {:ok, metadata_reference} = Cargo.metadata(context.cargo, options)
    assert_receive {:rekindle_cargo_ready, ^metadata_reference}, 60_000
    assert {:ok, metadata} = Cargo.result(context.cargo, metadata_reference, authority)

    assert metadata.inventory.selected_package.name == "rekindle-cargo-fixture"
    assert metadata.inventory.selected_target.name == Atom.to_string(target)

    assert Enum.map(metadata.inventory.local_packages, & &1.name) == [
             "rekindle-cargo-fixture",
             "rekindle-cargo-shared"
           ]

    assert metadata.inventory.has_local_build_script?
    assert metadata.inventory.target_directory == context.target_directory

    assert {:ok, build_reference} =
             Cargo.build(
               context.cargo,
               Keyword.put(options, :inventory, metadata.inventory)
             )

    assert_receive {:rekindle_cargo_ready, ^build_reference}, 60_000
    assert {:ok, result} = Cargo.result(context.cargo, build_reference, authority)
    assert result.build_key == identity.key
    assert result.artifact.sha256 == sha256(File.read!(result.artifact.path))
    result
  end

  defp options(context, target, config, authority) do
    [
      target: target,
      config: config,
      client_root: context.client_root,
      project_root: context.project_root,
      mode: :dev,
      rust_target: rust_target(target),
      authority: authority,
      target_directory: context.target_directory,
      process: process_policy()
    ]
  end

  defp config(:web) do
    %WebTarget{
      package: "rekindle-cargo-fixture",
      binary: "web",
      backend: :canonical,
      features: ["fixture-feature"],
      profiles: %{dev: "dev", release: "release"},
      public: nil,
      hot_styles: [],
      projection: %{mode: :phoenix_static, root: "priv/static"},
      toolchain: toolchain(:web),
      rust_target: rust_target(:web),
      default_features: false,
      environment: environment()
    }
  end

  defp config(:desktop) do
    %DesktopTarget{
      package: "rekindle-cargo-fixture",
      binary: "desktop",
      backend: :canonical,
      features: ["fixture-feature"],
      profiles: %{dev: "dev", release: "release"},
      runtime: %{
        readiness: :ipc_v1,
        startup_timeout_ms: 5_000,
        startup_grace_ms: nil,
        shutdown_timeout_ms: 2_000,
        replacement: :overlap,
        handoff: :enabled
      },
      projection: %{mode: :directory, root: "dist/desktop"},
      toolchain: toolchain(:desktop),
      rust_target: rust_target(:desktop),
      default_features: false,
      environment: environment()
    }
  end

  defp toolchain(:web), do: %{kind: :rustup, name: "1.95.0"}

  defp toolchain(:desktop) do
    %{
      kind: :path,
      cargo: System.find_executable("cargo") |> Path.expand(),
      rustc: System.find_executable("rustc") |> Path.expand(),
      identity: "system-1.95.0"
    }
  end

  defp environment do
    path = System.fetch_env!("PATH")

    %EnvironmentPolicy{
      inherit: :toolchain,
      set: [],
      unset: [],
      build_inputs: ["PATH"],
      redact: [],
      resolved: [{"PATH", path}]
    }
  end

  defp process_policy do
    %ProcessPolicy{
      build_timeout_ms: 60_000,
      terminate_grace_ms: 100,
      kill_grace_ms: 1_000,
      output_bytes_per_stream: 4 * 1_048_576,
      max_cargo_builds: 2,
      max_helper_jobs: 1
    }
  end

  defp authority_input(target) do
    node = if target == :web, do: :cargo_web, else: :cargo_desktop

    package = %{
      "kind" => "local",
      "manifest_path" => "client/Cargo.toml",
      "name" => "rekindle-cargo-fixture",
      "version" => "0.1.0"
    }

    model = %{
      "v" => 1,
      "node" => Atom.to_string(node),
      "target" => Atom.to_string(target),
      "package_identity" => package,
      "binary" => Atom.to_string(target),
      "local_package_identities" => [package],
      "has_local_build_script" => true,
      "cargo_input_paths" => [],
      "source_roots" => ["client"]
    }

    config = %{
      "v" => 1,
      "node" => Atom.to_string(node),
      "target" => Atom.to_string(target),
      "fields" => %{
        "package_identity" => package,
        "binary" => Atom.to_string(target),
        "rust_target" => rust_target(target),
        "profile" => "dev",
        "features" => ["fixture-feature"],
        "default_features" => false,
        "toolchain" => toolchain_identity(target),
        "environment_digest" => @digest
      }
    }

    assert {:ok, identity} =
             Identity.node_key(
               node: node,
               target: target,
               profile: "dev",
               model_slice: model,
               config: config,
               direct_inputs: [
                 %{"kind" => "value", "name" => "fixture", "value_digest" => @digest}
               ],
               tools: [
                 %{"name" => "cargo", "version" => "cargo 1.95.0", "content_digest" => nil},
                 %{"name" => "rustc", "version" => "rustc 1.95.0", "content_digest" => nil}
               ]
             )

    assert {:ok, scheduler} = Scheduler.new(target, 0)
    assert {:ok, scheduler, []} = Scheduler.change(scheduler, [node], 0)
    assert {:ok, scheduler, {:start, 1, [^node]}} = Scheduler.ready(scheduler, 0)
    {identity, scheduler}
  end

  defp rust_target(:web), do: "wasm32-unknown-unknown"
  defp rust_target(:desktop), do: "x86_64-unknown-linux-gnu"

  defp toolchain_identity(:web) do
    %{
      "kind" => "rustup",
      "name" => "1.95.0",
      "cargo_version" => "cargo 1.95.0",
      "rustc_vv" => "rustc 1.95.0",
      "rust_target" => rust_target(:web),
      "components" => []
    }
  end

  defp toolchain_identity(:desktop) do
    %{
      "kind" => "path",
      "declared_identity" => "system-1.95.0",
      "cargo_sha256" => @digest,
      "rustc_sha256" => @digest,
      "cargo_version" => "cargo 1.95.0",
      "rustc_vv" => "rustc 1.95.0",
      "rust_target" => rust_target(:desktop)
    }
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp temp_root(label) do
    Path.join(System.tmp_dir!(), "rekindle-cargo-#{label}-#{System.unique_integer([:positive])}")
  end
end
