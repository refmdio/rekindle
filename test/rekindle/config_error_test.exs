defmodule Rekindle.ConfigErrorTest do
  use ExUnit.Case, async: true

  alias Rekindle.ConfigError

  test "exposes the exact closed v1 value" do
    assert ConfigError.codes() ==
             [:invalid_type, :invalid_value, :unknown_key, :missing_key, :conflict]

    error = ConfigError.new(["targets", 0, String.duplicate("x", 128)], :invalid_value, "invalid")

    assert ConfigError.valid?(error)

    assert Map.keys(Map.from_struct(error)) |> Enum.sort() ==
             [:code, :contract_version, :message, :path]
  end

  test "enforces path, code, and message boundaries" do
    assert ConfigError.valid?(
             ConfigError.new(
               List.duplicate("x", 32),
               :conflict,
               String.duplicate("m", 4_096)
             )
           )

    for {path, code, message} <- [
          {List.duplicate("x", 33), :conflict, "invalid"},
          {[""], :conflict, "invalid"},
          {[String.duplicate("x", 129)], :conflict, "invalid"},
          {["é"], :conflict, "invalid"},
          {[-1], :conflict, "invalid"},
          {[9_007_199_254_740_992], :conflict, "invalid"},
          {[:atom], :conflict, "invalid"},
          {[], :unsupported, "invalid"},
          {[], :conflict, ""},
          {[], :conflict, String.duplicate("m", 4_097)},
          {[], :conflict, <<0>>}
        ] do
      assert_raise ArgumentError, fn -> ConfigError.new(path, code, message) end
    end
  end

  test "normalizes internal paths and legacy classifications before publication" do
    assert %ConfigError{path: ["targets", "é"], code: :missing_key} =
             ConfigError.from_internal([:targets, "é"], :config_missing, "missing")
  end

  test "redacts unsafe public message content at construction" do
    error = ConfigError.new([], :invalid_value, "invalid file /home/example/secret.txt")
    assert error.message == "invalid file <redacted-path>"

    raw = %{error | message: "invalid file /home/example/secret.txt"}
    refute ConfigError.valid?(raw)
  end
end
