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
end
