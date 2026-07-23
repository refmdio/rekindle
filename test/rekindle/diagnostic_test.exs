defmodule Rekindle.DiagnosticTest do
  use ExUnit.Case, async: false

  alias Rekindle.Diagnostic

  test "all public severities share one deterministic redacted projection" do
    previous = Application.get_env(:rekindle, :redact_values)
    Application.put_env(:rekindle, :redact_values, ["secret-value"])

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:rekindle, :redact_values),
        else: Application.put_env(:rekindle, :redact_values, previous)
    end)

    for severity <- [:error, :warning, :info] do
      assert {:ok, diagnostic} =
               Diagnostic.new(
                 target: :web,
                 stage: :execution,
                 severity: severity,
                 code: :cargo_compiler,
                 message: "secret-value at /home/user/client/src/main.rs",
                 file: "client/src/main.rs",
                 line: 2,
                 column: 4,
                 rendered: "secret-value"
               )

      projection = Diagnostic.to_map(diagnostic)
      assert projection["severity"] == Atom.to_string(severity)
      assert projection["file"] == "client/src/main.rs"
      assert projection["message"] == "<redacted> at <redacted-path>"
      assert projection["rendered"] == "<redacted>"
      refute Jason.encode!(projection) =~ "secret-value"
      refute Jason.encode!(projection) =~ "/home/user"
    end
  end

  test "external source attribution never exposes an absolute path" do
    assert {:ok, diagnostic} =
             Diagnostic.new(
               target: :desktop,
               stage: :execution,
               severity: :error,
               code: :cargo_compiler,
               message: "compiler failure",
               file: "<external>",
               line: 1
             )

    assert Diagnostic.to_map(diagnostic)["file"] == "<external>"
  end

  test "enforces closed codes, text bounds, locations, and normalized controls" do
    base = [
      target: nil,
      stage: :internal,
      severity: :error,
      code: :internal_error,
      message: "safe"
    ]

    assert {:ok, _diagnostic} =
             Diagnostic.new(Keyword.put(base, :message, String.duplicate("x", 4_096)))

    assert {:error, _error} =
             Diagnostic.new(Keyword.put(base, :message, String.duplicate("x", 4_097)))

    assert {:ok, _diagnostic} =
             Diagnostic.new(Keyword.put(base, :rendered, String.duplicate("x", 16_384)))

    assert {:error, _error} =
             Diagnostic.new(Keyword.put(base, :rendered, String.duplicate("x", 16_385)))

    for code <- [
          :Uppercase,
          :"bad-code",
          :"1bad",
          String.to_atom("a" <> String.duplicate("b", 64))
        ] do
      assert {:error, _error} = Diagnostic.new(Keyword.put(base, :code, code))
    end

    for message <- ["control\tbyte", "carriage\rreturn", "cafe\u0301"] do
      assert {:error, _error} = Diagnostic.new(Keyword.put(base, :message, message))
    end

    assert {:ok, _diagnostic} =
             Diagnostic.new(base ++ [file: "src/main.rs", line: 4_294_967_295])

    assert {:error, _error} =
             Diagnostic.new(base ++ [file: "src/main.rs", line: 4_294_967_296])

    assert {:error, _error} =
             Diagnostic.new(base ++ [file: String.duplicate("x", 1_025)])
  end
end
