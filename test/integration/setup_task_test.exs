defmodule Rekindle.SetupTaskIntegrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Rekindle.Toolchain.{Installer, Release}

  setup do
    root = temp_dir!()
    rustup = fake_rustup!(root)
    log = Path.join(root, "rustup.log")
    helper = "preinstalled helper fixture"
    manifest = manifest!(root, helper)

    previous = %{
      build: Application.get_env(:rekindle, :rekindle_build),
      dev: Application.get_env(:rekindle, :rekindle_dev),
      manifest: Application.get_env(:rekindle, :compatibility_manifest),
      redact_values: Application.get_env(:rekindle, :redact_values),
      rustup: System.get_env("REKINDLE_RUSTUP"),
      rustup_log: System.get_env("REKINDLE_RUSTUP_LOG"),
      cache: System.get_env("XDG_CACHE_HOME")
    }

    Application.put_env(:rekindle, :rekindle_build, build_config())
    Application.put_env(:rekindle, :rekindle_dev, dev_config())
    Application.put_env(:rekindle, :compatibility_manifest, manifest)
    System.put_env("REKINDLE_RUSTUP", rustup)
    System.put_env("REKINDLE_RUSTUP_LOG", log)
    System.put_env("XDG_CACHE_HOME", root)

    assert {:ok, _path} =
             Release.ensure(false,
               manifest_path: manifest,
               cache_root: Path.join(root, "rekindle/helpers"),
               fetcher: fn _url -> helper end
             )

    on_exit(fn ->
      restore_app_env(:rekindle_build, previous.build)
      restore_app_env(:rekindle_dev, previous.dev)
      restore_app_env(:compatibility_manifest, previous.manifest)
      restore_app_env(:redact_values, previous.redact_values)
      restore_system_env("REKINDLE_RUSTUP", previous.rustup)
      restore_system_env("REKINDLE_RUSTUP_LOG", previous.rustup_log)
      restore_system_env("XDG_CACHE_HOME", previous.cache)
    end)

    {:ok, rustup_log: log}
  end

  test "the public setup task succeeds with a qualified rustup and preinstalled helper",
       context do
    outcome = Mix.Tasks.Rekindle.Setup.run_outcome(["--target", "web"])

    assert outcome.exit_status == 0, inspect(outcome)
    assert outcome.stdout =~ "web target verified"
    assert outcome.stdout =~ "helper verified"

    assert File.read!(context.rustup_log) ==
             "toolchain install 1.95.0 --profile minimal\n" <>
               "target add --toolchain 1.95.0 wasm32-unknown-unknown\n"
  end

  test "the public Mix task preserves success status", context do
    output =
      capture_io(fn ->
        assert :ok = Mix.Tasks.Rekindle.Setup.run(["--target", "web"])
      end)

    assert output =~ "web target verified"
    assert output =~ "helper verified"

    assert File.read!(context.rustup_log) ==
             "toolchain install 1.95.0 --profile minimal\n" <>
               "target add --toolchain 1.95.0 wasm32-unknown-unknown\n"
  end

  test "the real setup adapter closes every backend ConfigError family into exit 1", context do
    cases = [
      {:integer_out_of_range, %{"value" => 9_007_199_254_740_992}},
      {:invalid_utf8, %{"value" => <<255>>}},
      {:invalid_map_key, %{atom_key: true}},
      {:non_nfc_key, %{"e\u0301" => true}},
      {:unsupported_value, %{"value" => {:tuple}}},
      {:backend_specific, %{"custom_error" => true}}
    ]

    for {family, options} <- cases do
      Application.put_env(
        :rekindle,
        :rekindle_build,
        external_build_config(__MODULE__.ConfigErrorBackend, options)
      )

      outcome = Mix.Tasks.Rekindle.Setup.run_outcome([])
      assert outcome.exit_status == 1, inspect({family, outcome})
      assert outcome.value |> elem(1) |> Map.fetch!(:code) == :config_invalid
      refute File.exists?(context.rustup_log)
      assert outcome.stdout == ""
      assert outcome.stderr =~ "config_invalid"
    end

    Application.delete_env(:rekindle, :rekindle_build)

    for malformed <- [:malformed, ["a" | :bad]] do
      Application.put_env(:rekindle, :redact_values, malformed)
      outcome = Mix.Tasks.Rekindle.Setup.run_outcome([])
      assert outcome.exit_status == 1
      assert outcome.value |> elem(1) |> Map.fetch!(:code) == :config_missing
      assert outcome.stderr =~ "config_missing"
    end
  end

  test "the public Mix task preserves semantic nonzero statuses through subprocess exit" do
    mix = System.find_executable("mix") || raise "mix executable is required"

    {invalid_output, invalid_status} =
      System.cmd(mix, ["rekindle.setup", "--target", "mobile"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert invalid_status == 2
    assert invalid_output =~ "config_invalid"
    refute invalid_output =~ "** (Mix)"

    {expected_output, expected_status} =
      System.cmd(mix, ["rekindle.setup"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert expected_status == 1
    assert expected_output =~ "config_missing"
    refute expected_output =~ "** (Mix)"

    {json_output, json_status} =
      System.cmd(mix, ["rekindle.setup", "--json"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert json_status == 2
    assert json_output =~ "config_invalid"
    assert json_output =~ "--json"
    refute json_output =~ ~s("status":"error")
    refute json_output =~ "config_missing"
    refute json_output =~ "** (Mix)"

    assert_semantic_exit_boundary()
  end

  defp build_config do
    [
      schema: 1,
      client: "crates/rekindle-toolchain",
      targets: [
        web: [
          package: "rekindle_ui",
          binary: "rekindle-web",
          toolchain: [kind: :rustup, name: "1.95.0"],
          rust_target: "wasm32-unknown-unknown",
          features: ["web"],
          projection: [mode: :phoenix_static, root: "priv/static/rekindle"]
        ]
      ]
    ]
  end

  defp dev_config do
    [schema: 1, enabled: true, targets: [:web], endpoint: __MODULE__.Endpoint]
  end

  defp external_build_config(module, options) do
    [
      schema: 1,
      client: "crates/rekindle-toolchain",
      targets: [
        web: [
          package: "rekindle_ui",
          binary: "rekindle-web",
          features: ["web"],
          projection: [mode: :phoenix_static, root: "priv/static/rekindle"],
          backend: [module: module, options: options]
        ]
      ]
    ]
  end

  defp manifest!(root, helper) do
    host = Installer.host()

    asset = %{
      "os" => host.os,
      "arch" => host.arch,
      "url" => "https://fixtures.invalid/rekindle_toolchain",
      "size" => byte_size(helper),
      "sha256" => sha256(helper)
    }

    bytes = Rekindle.CompatibilityFixture.encode(asset)

    path = Path.join(root, "compatibility.json")
    File.write!(path, bytes)
    path
  end

  defp fake_rustup!(root) do
    path = Path.join(root, "rustup")

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$REKINDLE_RUSTUP_LOG"
    """)

    File.chmod!(path, 0o700)
    path
  end

  defp assert_semantic_exit_boundary do
    elixir = System.find_executable("elixir") || raise "elixir executable is required"
    ebin = Path.expand("_build/test/lib/rekindle/ebin")

    for status <- 0..3 do
      {stdout, stderr, value} =
        if status == 0,
          do: {"status-0\n", "", "{:ok, nil}"},
          else: {"", "status-#{status}\n", "{:error, nil}"}

      expression = """
      Mix.start()
      outcome = %Rekindle.Command.Outcome{
        exit_status: #{status},
        stdout: #{inspect(stdout)},
        stderr: #{inspect(stderr)},
        value: #{value}
      }
      Rekindle.Command.emit_and_exit(outcome)
      """

      {output, actual_status} =
        System.cmd(elixir, ["-pa", ebin, "-e", expression], stderr_to_stdout: true)

      assert actual_status == status
      assert output == "status-#{status}\n"
      refute output =~ "** (Mix)"
    end
  end

  defp temp_dir! do
    path =
      Path.join(System.tmp_dir!(), "rekindle-setup-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:rekindle, key)
  defp restore_app_env(key, value), do: Application.put_env(:rekindle, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defmodule Endpoint do
  end

  defmodule ConfigErrorBackend do
    @behaviour Rekindle.TargetBackend

    @impl true
    def backend_id, do: "setup-config-error-fixture"

    @impl true
    def backend_version, do: "1"

    @impl true
    def validate(_target, %{"custom_error" => true}) do
      {:error,
       [Rekindle.ConfigError.new([:backend, :options], :backend_specific, "custom error")]}
    end

    def validate(_target, options), do: {:ok, options}

    @impl true
    def plan(_context, _options), do: raise("not invoked")

    @impl true
    def finalize(_context, _options, _result), do: raise("not invoked")
  end
end
