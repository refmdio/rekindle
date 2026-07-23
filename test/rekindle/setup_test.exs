defmodule Rekindle.SetupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Rekindle.{Config, Failure, Setup}

  test "defaults to all declared targets and verifies the helper last" do
    parent = self()

    outcome =
      Setup.run([],
        load_project: fn -> {:ok, project([:web, :desktop])} end,
        ensure_target: fn target, config ->
          send(parent, {:target, target})
          assert config == project([:web, :desktop]).build.targets[target]
          {:ok, :installed}
        end,
        ensure_helper: fn source? ->
          send(parent, {:helper, source?})
          {:ok, :installed}
        end
      )

    assert outcome.exit_status == 0
    assert_receive {:target, :desktop}
    assert_receive {:target, :web}
    assert_receive {:helper, false}
    assert outcome.stdout =~ "desktop target verified"
    assert outcome.stdout =~ "helper verified"
  end

  test "accepts every exact target and explicit source helper build" do
    for {value, expected} <- [{"web", :web}, {"desktop", :desktop}, {"all", :all}] do
      parent = self()

      outcome =
        Setup.run(["--target", value, "--source-build-helper"],
          load_project: fn -> {:ok, project([:web, :desktop])} end,
          ensure_target: fn target, _config ->
            send(parent, {:target, target})
            {:ok, :present}
          end,
          ensure_helper: fn source? ->
            send(parent, {:source, source?})
            {:ok, :built}
          end
        )

      assert outcome.exit_status == 0
      assert_receive {:source, true}

      if expected == :all do
        assert outcome.value |> elem(1) |> Map.fetch!(:targets) |> length() == 2
      else
        assert_receive {:target, ^expected}
      end
    end
  end

  test "rejects unknown grammar before project load" do
    parent = self()

    adapters = [
      load_project: fn ->
        send(parent, :loaded)
        {:ok, project([:web])}
      end,
      ensure_target: fn _, _ -> {:ok, :present} end,
      ensure_helper: fn _ -> {:ok, :present} end
    ]

    for argv <- [
          ["web"],
          ["--unknown"],
          ["--json"],
          ["--target", "mobile"],
          ["--no-source-build-helper"],
          ["--source-build-helper=false"],
          ["--source-build-helper=true"],
          ["--source-build-helper", "--source-build-helper"],
          ["--target", "desktop", "--target", "web"],
          ["--target=desktop", "--target", "web"],
          ["--"],
          ["--target", "web", "--"]
        ] do
      outcome = Setup.run(argv, adapters)
      assert outcome.exit_status == 2
      assert outcome.stdout == ""
      assert outcome.stderr =~ "config_invalid"
      refute_received :loaded
    end
  end

  test "maps target and helper failures to typed exit 1 and stops effects" do
    parent = self()

    target_failure =
      Failure.new!(
        target: :web,
        stage: :compatibility,
        code: :tool_missing,
        message: "rust target missing"
      )

    target_outcome =
      Setup.run(["--target", "web"],
        load_project: fn -> {:ok, project([:web])} end,
        ensure_target: fn :web, _config -> {:error, target_failure} end,
        ensure_helper: fn _ ->
          send(parent, :helper)
          {:ok, :present}
        end
      )

    assert target_outcome.exit_status == 1
    assert target_outcome.stdout == ""
    assert target_outcome.stderr =~ "tool_missing"
    refute_received :helper

    helper_failure =
      Failure.new!(
        target: nil,
        stage: :compatibility,
        code: :helper_checksum_mismatch,
        message: "bad helper"
      )

    helper_outcome =
      Setup.run([],
        load_project: fn -> {:ok, project([:web])} end,
        ensure_target: fn :web, _config -> {:ok, :present} end,
        ensure_helper: fn false -> {:error, helper_failure} end
      )

    assert helper_outcome.exit_status == 1
    assert helper_outcome.stdout == ""
    assert helper_outcome.stderr =~ "helper_checksum_mismatch"
  end

  test "rejects the undeclared JSON switch with the shared human invocation failure" do
    parent = self()

    adapters = [
      load_project: fn ->
        send(parent, :loaded)
        {:ok, project([:web])}
      end,
      ensure_target: fn :web, _config -> {:ok, :present} end,
      ensure_helper: fn false -> {:ok, :present} end
    ]

    outcome = Setup.run(["--json"], adapters)
    assert outcome.exit_status == 2
    assert outcome.stdout == ""
    assert outcome.stderr =~ "config_invalid"
    assert outcome.stderr =~ "--json"
    refute_received :loaded
  end

  test "is idempotent and performs no application source or runtime mutation" do
    counter = :counters.new(2, [])
    before_ports = MapSet.new(Port.list())

    adapters = [
      load_project: fn -> {:ok, project([:desktop])} end,
      ensure_target: fn :desktop, _config ->
        :counters.add(counter, 1, 1)
        {:ok, :present}
      end,
      ensure_helper: fn false ->
        :counters.add(counter, 2, 1)
        {:ok, :present}
      end
    ]

    assert Setup.run([], adapters).exit_status == 0
    assert Setup.run([], adapters).exit_status == 0
    assert :counters.get(counter, 1) == 2
    assert :counters.get(counter, 2) == 2
    assert before_ports == MapSet.new(Port.list())
  end

  test "maps every unavailable setup adapter to correlated internal exit 3" do
    cases = [
      [],
      [load_project: fn -> {:ok, project([:web])} end],
      [
        load_project: fn -> {:ok, project([:web])} end,
        ensure_target: fn :web, _config -> {:ok, :present} end
      ]
    ]

    for adapters <- cases do
      {outcome, log} = with_log(fn -> Setup.run([], adapters) end)
      public = outcome.stdout <> outcome.stderr

      assert outcome.exit_status == 3

      assert [[correlation]] =
               Regex.scan(~r/correlation=([0-9a-f]{32})/, public, capture: :all_but_first)

      assert Regex.scan(~r/correlation=([0-9a-f]{32})/, log, capture: :all_but_first) == [
               [correlation]
             ]

      assert public =~ "contract_violation"
      refute public =~ "adapter"
      assert log =~ "setup adapter"
      assert byte_size(log) < 10_000
    end
  end

  test "maps malformed extension configuration to a sanitized contract failure" do
    error =
      Rekindle.ConfigError.new(
        ["backend", "options"],
        :invalid_value,
        "private callback detail"
      )

    outcome =
      Setup.run([],
        load_project: fn -> {:error, {:invalid_configuration_errors, error}} end,
        ensure_target: fn _, _ -> flunk("target installation must not start") end,
        ensure_helper: fn _ -> flunk("helper installation must not start") end
      )

    assert outcome.exit_status == 3
    assert {:error, %Failure{code: :contract_violation, diagnostics: []}} = outcome.value
    assert outcome.stderr =~ "contract_violation"
    assert outcome.stderr =~ ~r/correlation=[0-9a-f]{32}/
    refute outcome.stderr =~ "private callback detail"
    refute outcome.stderr =~ "extension configuration error contract violation"
  end

  defp project(targets) do
    target_configs =
      Enum.map(targets, fn
        :web -> {:web, web_target()}
        :desktop -> {:desktop, desktop_target()}
      end)

    {:ok, project} =
      Config.normalize(:setup_test, [schema: 1, client: "lib", targets: target_configs],
        schema: 1,
        enabled: true,
        targets: [List.first(targets)],
        endpoint: if(:web == List.first(targets), do: __MODULE__.Endpoint, else: nil)
      )

    project
  end

  defp web_target do
    [
      package: "setup_ui",
      binary: "setup-web",
      toolchain: [kind: :rustup, name: "1.95.0"],
      rust_target: "wasm32-unknown-unknown",
      features: ["web"],
      projection: [mode: :phoenix_static, root: "priv/static/rekindle"]
    ]
  end

  defp desktop_target do
    [
      package: "setup_ui",
      binary: "setup",
      toolchain: [kind: :rustup, name: "1.95.0"],
      features: ["desktop"],
      projection: [mode: :directory, root: "dist/rekindle/desktop"]
    ]
  end

  defmodule Endpoint do
  end
end
