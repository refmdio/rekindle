defmodule Rekindle.CommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Rekindle.{Command, Failure}

  @grammar [switches: [json: :boolean, release: :boolean], positionals: 1]

  test "rejects grammar before loading project state" do
    parent = self()

    handler = fn invocation ->
      send(parent, {:called, invocation})
      {:ok, %{}}
    end

    outcome = Command.run("rekindle.example", ["web", "extra"], @grammar, handler)
    assert outcome.exit_status == 2
    assert outcome.stdout == ""
    assert outcome.stderr =~ "config_invalid"
    refute_received {:called, _}

    for argv <- [["--"], ["web", "--"], ["--", "web"]] do
      outcome = Command.run("rekindle.example", argv, @grammar, handler)
      assert outcome.exit_status == 2, inspect(argv)
      assert outcome.stdout == ""
      assert outcome.stderr =~ "unknown or invalid option: --"
      refute_received {:called, _}
    end

    json = Command.run("rekindle.example", ["web", "--unknown", "x", "--json"], @grammar, handler)
    assert json.exit_status == 2
    assert Jason.decode!(json.stdout)["status"] == "error"
    assert json.stderr == ""
    refute_received {:called, _}
  end

  test "rejects noncanonical booleans and duplicate options before invoking the handler" do
    parent = self()

    handler = fn invocation ->
      send(parent, {:called, invocation})
      {:ok, %{}}
    end

    alias_grammar = Keyword.put(@grammar, :aliases, j: :json, r: :release)
    target_grammar = [switches: [target: :string], aliases: [t: :target], positionals: 0]

    invalid = [
      {@grammar, ["web", "--no-json"]},
      {@grammar, ["web", "--json=false"]},
      {@grammar, ["web", "--release=true"]},
      {@grammar, ["web", "--json", "--json"]},
      {@grammar, ["web", "--release", "--release"]},
      {@grammar, ["web", "--json", "--no-json"]},
      {alias_grammar, ["web", "-j=false"]},
      {alias_grammar, ["web", "-j", "-j"]},
      {alias_grammar, ["web", "--json", "-j"]},
      {alias_grammar, ["web", "-jr"]},
      {target_grammar, ["--target", "desktop", "--target", "web"]},
      {target_grammar, ["--target=desktop", "-t", "web"]},
      {target_grammar, ["--target", "web", "--"]}
    ]

    for {grammar, argv} <- invalid do
      outcome = Command.run("rekindle.example", argv, grammar, handler)
      assert outcome.exit_status == 2, inspect(argv)
      assert outcome.value |> elem(1) |> Map.fetch!(:code) == :config_invalid
      refute_received {:called, _}
    end

    accepted = Command.run("rekindle.example", ["--target=web"], target_grammar, handler)
    assert accepted.exit_status == 0
    assert_receive {:called, %{options: %{target: "web"}}}

    for argv <- [["web", "--json", "--json"], ["web", "-j", "-j"]] do
      outcome = Command.run("rekindle.example", argv, alias_grammar, handler)
      assert outcome.exit_status == 2
      assert outcome.stderr == ""
      assert String.split(outcome.stdout, "\n", trim: true) |> length() == 1

      assert outcome.stdout ==
               Rekindle.CanonicalValue.encode!(Jason.decode!(outcome.stdout)) <> "\n"

      assert Jason.decode!(outcome.stdout)["failure"]["code"] == "config_invalid"
      refute_received {:called, _}
    end

    value_json_grammar = [
      switches: [output: :string, json: :boolean],
      aliases: [j: :json],
      positionals: 0
    ]

    missing_value =
      Command.run("rekindle.example", ["--output", "-j"], value_json_grammar, handler)

    assert missing_value.exit_status == 2
    assert missing_value.stderr == ""
    assert Jason.decode!(missing_value.stdout)["failure"]["code"] == "config_invalid"
    refute_received {:called, _}
  end

  test "preserves canonical separated and assigned numeric option values" do
    parent = self()

    grammar = [
      switches: [number: :integer, ratio: :float],
      aliases: [n: :number, r: :ratio],
      positionals: 0
    ]

    cases = [
      {["--number", "-1"], %{number: -1}},
      {["-n", "-1"], %{number: -1}},
      {["--ratio", "-1.5"], %{ratio: -1.5}},
      {["-r", "-1.5"], %{ratio: -1.5}},
      {["--number=-1"], %{number: -1}},
      {["-n=-1"], %{number: -1}},
      {["--ratio=-1.5"], %{ratio: -1.5}},
      {["-r=-1.5"], %{ratio: -1.5}}
    ]

    for {argv, expected} <- cases do
      outcome =
        Command.run("rekindle.example", argv, grammar, fn invocation ->
          send(parent, {:options, invocation.options})
          {:ok, %{}}
        end)

      assert outcome.exit_status == 0, inspect(argv)
      assert_receive {:options, ^expected}
    end
  end

  test "preserves separated string values beginning with a hyphen and digit" do
    parent = self()
    grammar = [switches: [value: :string], aliases: [v: :value], positionals: 0]

    for {argv, expected} <- [
          {["--value", "-0x1"], "-0x1"},
          {["-v", "-1foo"], "-1foo"},
          {["--value", "-1.2foo"], "-1.2foo"}
        ] do
      outcome =
        Command.run("rekindle.example", argv, grammar, fn invocation ->
          send(parent, {:value, invocation.options.value})
          {:ok, %{}}
        end)

      assert outcome.exit_status == 0, inspect(argv)
      assert_receive {:value, ^expected}
    end
  end

  test "human success uses stdout and expected failure uses stderr" do
    success =
      Command.run("rekindle.example", ["web"], @grammar, fn _ ->
        {:ok, %{target: :web}, ["building"]}
      end)

    assert success.exit_status == 0
    assert success.stdout == "building\n{\"target\":\"web\"}\n"
    assert success.stderr == ""

    failure = failure()

    failed =
      Command.run("rekindle.example", ["web"], @grammar, fn _ ->
        {:error, failure, ["building"]}
      end)

    assert failed.exit_status == 1
    assert failed.stdout == "building\n"
    assert failed.stderr == "[web] cargo_failed: Cargo failed\n"
  end

  test "JSON mode emits one canonical object and exactly one terminal union arm" do
    success =
      Command.run("rekindle.example", ["web", "--json"], @grammar, fn _ ->
        {:ok, %{z: 2, a: 1}, ["hidden"]}
      end)

    assert success.exit_status == 0
    assert String.split(success.stdout, "\n", trim: true) |> length() == 1

    assert success.stdout ==
             Rekindle.CanonicalValue.encode!(Jason.decode!(success.stdout)) <> "\n"

    assert %{"result" => %{"a" => 1, "z" => 2}, "failure" => nil} = Jason.decode!(success.stdout)

    failed =
      Command.run("rekindle.example", ["web", "--json"], @grammar, fn _ -> {:error, failure()} end)

    assert failed.exit_status == 1

    assert %{"result" => nil, "failure" => %{"code" => "cargo_failed"}} =
             Jason.decode!(failed.stdout)

    assert failed.stderr == ""
  end

  test "contains invalid handler values and exceptions as exit 3 without stacks" do
    {invalid, _log} =
      with_log(fn -> Command.run("rekindle.example", ["web"], @grammar, fn _ -> :invalid end) end)

    {raised, _log} =
      with_log(fn ->
        Command.run("rekindle.example", ["web", "--json"], @grammar, fn _ ->
          raise "secret stack"
        end)
      end)

    assert invalid.exit_status == 3
    assert invalid.stderr =~ "contract_violation"
    refute invalid.stderr =~ "command_test.exs"

    assert raised.exit_status == 3
    assert Jason.decode!(raised.stdout)["failure"]["code"] == "contract_violation"
    refute raised.stdout =~ "secret stack"
    refute raised.stdout =~ "command_test.exs"
  end

  test "classifies handler-declared invocation failures as exit 2" do
    invocation_failure =
      Failure.new!(
        target: nil,
        stage: :configuration,
        code: :config_invalid,
        message: "invalid target"
      )

    human =
      Command.run("rekindle.example", ["web"], @grammar, fn _ ->
        {:error, :invocation, invocation_failure}
      end)

    assert human.exit_status == 2
    assert human.stdout == ""
    assert human.stderr == "config_invalid: invalid target\n"

    json =
      Command.run("rekindle.example", ["web", "--json"], @grammar, fn _ ->
        {:error, :invocation, invocation_failure}
      end)

    assert json.exit_status == 2
    assert json.stderr == ""
    assert Jason.decode!(json.stdout)["failure"]["code"] == "config_invalid"
  end

  test "classifies structurally unsafe Failure values as exit 3" do
    unsafe = %{failure() | message: <<255>>}

    for argv <- [["web"], ["web", "--json"]] do
      {outcome, _log} =
        with_log(fn ->
          Command.run("rekindle.example", argv, @grammar, fn _ -> {:error, unsafe} end)
        end)

      assert outcome.exit_status == 3
      rendered = outcome.stdout <> outcome.stderr
      assert rendered =~ "contract_violation"
      refute rendered =~ <<255>>
    end
  end

  test "classifies every typed internal code as correlated exit 3 in human and JSON modes" do
    for code <- internal_codes(), argv <- [["web"], ["web", "--json"]] do
      failure =
        Failure.new!(
          target: nil,
          stage: :internal,
          code: code,
          message: "typed internal context"
        )

      {outcome, log} =
        with_log(fn ->
          Command.run("rekindle.example", argv, @grammar, fn _ ->
            {:error, failure, ["must not emit"]}
          end)
        end)

      assert_correlated_internal(outcome, log, "typed internal context")
      refute outcome.stdout <> outcome.stderr =~ "must not emit"
    end
  end

  test "contains raise, throw, and exit with sanitized correlated diagnostics" do
    previous = Application.get_env(:rekindle, :redact_values)

    secrets = ["raised-secret", "thrown-secret", "exit-secret"]
    Application.put_env(:rekindle, :redact_values, secrets)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:rekindle, :redact_values, previous),
        else: Application.delete_env(:rekindle, :redact_values)
    end)

    operations = [
      fn -> raise "raised-secret raw exception" end,
      fn -> throw({:failure, "thrown-secret"}) end,
      fn -> exit({:failure, "exit-secret"}) end
    ]

    for operation <- operations, argv <- [["web"], ["web", "--json"]] do
      {outcome, log} =
        with_log(fn ->
          Command.run("rekindle.example", argv, @grammar, fn _ -> operation.() end)
        end)

      assert_correlated_internal(outcome, log, nil)

      for secret <- secrets do
        refute outcome.stdout =~ secret
        refute outcome.stderr =~ secret
        refute log =~ secret
      end

      refute outcome.stdout =~ "command_test.exs"
      refute outcome.stderr =~ "command_test.exs"
      assert log =~ "context=kind="
      assert byte_size(log) < 10_000
    end
  end

  test "keeps non-internal typed failures in expected exit class" do
    for code <- Failure.codes() -- internal_codes(), argv <- [["web"], ["web", "--json"]] do
      {:ok, stage} = Failure.stage_for(code)

      failure =
        Failure.new!(target: nil, stage: stage, code: code, message: "expected failure")

      {outcome, log} =
        with_log(fn ->
          Command.run("rekindle.example", argv, @grammar, fn _ -> {:error, failure} end)
        end)

      assert outcome.exit_status == 1
      refute outcome.stdout <> outcome.stderr =~ "correlation="
      assert log == ""
    end
  end

  defp internal_codes do
    Enum.filter(Failure.codes(), &(Failure.stage_for(&1) == {:ok, :internal}))
  end

  defp assert_correlated_internal(outcome, log, local_context) do
    public = outcome.stdout <> outcome.stderr

    assert outcome.exit_status == 3

    assert [[correlation]] =
             Regex.scan(~r/correlation=([0-9a-f]{32})/, public, capture: :all_but_first)

    assert Regex.scan(~r/correlation=([0-9a-f]{32})/, log, capture: :all_but_first) == [
             [correlation]
           ]

    assert public =~ "contract_violation"
    refute public =~ "stack="

    if local_context do
      refute public =~ local_context
      assert log =~ local_context
    end

    if outcome.stdout != "" do
      assert outcome.stderr == ""
      assert String.split(outcome.stdout, "\n", trim: true) |> length() == 1

      assert outcome.stdout ==
               Rekindle.CanonicalValue.encode!(Jason.decode!(outcome.stdout)) <> "\n"
    else
      assert outcome.stderr != ""
    end
  end

  defp failure do
    Failure.new!(target: :web, stage: :execution, code: :cargo_failed, message: "Cargo failed")
  end
end
