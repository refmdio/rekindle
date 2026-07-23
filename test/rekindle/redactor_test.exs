defmodule Rekindle.RedactorTest do
  use ExUnit.Case, async: false

  alias Rekindle.Redactor

  test "redacts binary patterns longest-first without decoding the input" do
    assert {:ok, redacted} =
             Redactor.redact_bytes(<<255, "private-token private", 0>>, [
               "private",
               "private-token"
             ])

    assert redacted == <<255, "<redacted> <redacted>", 0>>
  end

  test "does not scan replacement markers as input" do
    assert {:ok, "<redacted>"} = Redactor.redact_bytes("value", ["value", "<redacted>"])
  end

  test "ignores malformed application configuration safely" do
    previous = Application.get_env(:rekindle, :redact_values)
    Application.put_env(:rekindle, :redact_values, ["safe", :invalid])

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:rekindle, :redact_values),
        else: Application.put_env(:rekindle, :redact_values, previous)
    end)

    assert {:ok, "<redacted> invalid"} = Redactor.redact_bytes("safe invalid")
  end
end
