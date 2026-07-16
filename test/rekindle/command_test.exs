defmodule Rekindle.CommandTest do
  use ExUnit.Case, async: true

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

    json = Command.run("rekindle.example", ["web", "--unknown", "x", "--json"], @grammar, handler)
    assert json.exit_status == 2
    assert Jason.decode!(json.stdout)["status"] == "error"
    assert json.stderr == ""
    refute_received {:called, _}
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
    invalid = Command.run("rekindle.example", ["web"], @grammar, fn _ -> :invalid end)

    raised =
      Command.run("rekindle.example", ["web", "--json"], @grammar, fn _ ->
        raise "secret stack"
      end)

    assert invalid.exit_status == 3
    assert invalid.stderr =~ "contract_violation"
    refute invalid.stderr =~ "command_test.exs"

    assert raised.exit_status == 3
    assert Jason.decode!(raised.stdout)["failure"]["code"] == "contract_violation"
    refute raised.stdout =~ "secret stack"
    refute raised.stdout =~ "command_test.exs"
  end

  defp failure do
    Failure.new!(target: :web, stage: :execution, code: :cargo_failed, message: "Cargo failed")
  end
end
