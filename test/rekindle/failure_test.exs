defmodule Rekindle.FailureTest do
  use ExUnit.Case, async: false

  alias Rekindle.{Diagnostic, Failure}

  @groups %{
    configuration:
      ~w[config_missing config_invalid target_undeclared path_invalid path_overlap install_conflict]a,
    compatibility:
      ~w[tool_missing tool_version_mismatch helper_missing helper_checksum_mismatch helper_protocol_mismatch unsupported_host unqualified_tuple]a,
    project_model:
      ~w[cargo_metadata_failed package_not_found target_not_found target_ambiguous feature_invalid lockfile_required]a,
    execution:
      ~w[spawn_failed io_failed cargo_failed cargo_protocol build_timeout cancelled cleanup_unconfirmed output_limit]a,
    web_toolchain:
      ~w[bindgen_failed wasm_schema_mismatch web_graph_invalid unsupported_import asset_collision]a,
    artifact:
      ~w[artifact_missing artifact_ambiguous artifact_changed manifest_invalid seal_failed cache_corrupt generation_limit]a,
    activation:
      ~w[browser_protocol browser_disconnected browser_runtime_failed native_not_ready native_exited handoff_failed]a,
    production:
      ~w[projection_busy projection_invalid digest_failed digest_output_invalid foreign_projection_change release_not_ready]a,
    internal: ~w[contract_violation unexpected_state internal]a
  }

  test "owns the exact v1 failure taxonomy and code-stage pairing" do
    assert Failure.stages() |> Enum.sort() == Map.keys(@groups) |> Enum.sort()

    assert Failure.codes() |> Enum.sort() ==
             @groups |> Map.values() |> List.flatten() |> Enum.sort()

    for {stage, codes} <- @groups, code <- codes do
      assert {:ok, ^stage} = Failure.stage_for(code)

      assert {:ok, %Failure{stage: ^stage, code: ^code}} =
               Failure.new(target: nil, stage: stage, code: code, message: "safe")
    end
  end

  test "enforces the exact retryable classification" do
    expected =
      ~w[spawn_failed io_failed build_timeout cancelled browser_disconnected native_not_ready projection_busy]a

    for code <- Failure.codes() do
      assert Failure.retryable?(code) == code in expected
    end

    assert {:error, _} =
             Failure.new(
               target: :web,
               stage: :execution,
               code: :cargo_failed,
               message: "failed",
               retryable?: true
             )
  end

  test "rejects unknown versions, fields, codes, and mismatched stages" do
    base = %{target: :web, stage: :execution, code: :cargo_failed, message: "failed"}

    assert {:error, _} = Failure.new(Map.put(base, :contract_version, 2))
    assert {:error, _} = Failure.new(Map.put(base, :stacktrace, []))
    assert {:error, _} = Failure.new(%{base | code: :unknown})
    assert {:error, _} = Failure.new(%{base | stage: :artifact})
  end

  test "diagnostics accept only closed safe locations" do
    assert {:ok, diagnostic} =
             Diagnostic.new(
               target: :web,
               stage: :execution,
               severity: :error,
               code: :cargo,
               message: "compiler error",
               file: "client/src/main.rs",
               line: 7,
               column: 3,
               rendered: "error at main.rs"
             )

    assert {:ok, failure} =
             Failure.new(
               target: :web,
               stage: :execution,
               code: :cargo_failed,
               message: "Cargo failed",
               diagnostics: [diagnostic]
             )

    assert Failure.to_map(failure) == %{
             "contract_version" => 1,
             "target" => "web",
             "stage" => "execution",
             "code" => "cargo_failed",
             "message" => "Cargo failed",
             "diagnostics" => [Diagnostic.to_map(diagnostic)],
             "retryable" => false
           }

    assert Failure.render(failure) == "[web] cargo_failed: Cargo failed"

    assert {:error, _} =
             Diagnostic.new(
               target: :web,
               stage: :execution,
               severity: :error,
               code: :x,
               message: "x",
               file: "/secret/path"
             )

    assert {:error, _} =
             Diagnostic.new(
               target: :web,
               stage: :execution,
               severity: :error,
               code: :x,
               message: "x",
               line: 1
             )
  end

  test "closed structs expose exactly the public fields" do
    assert Map.keys(Failure.__struct__()) |> Enum.sort() ==
             ~w[__struct__ code contract_version diagnostics message retryable? stage target]a
             |> Enum.sort()

    assert Map.keys(Diagnostic.__struct__()) |> Enum.sort() ==
             ~w[__struct__ code column contract_version file line message rendered severity stage target]a
             |> Enum.sort()
  end

  test "redacts registered secrets and absolute paths before every public sink" do
    previous = Application.get_env(:rekindle, :redact_values)
    Application.put_env(:rekindle, :redact_values, ["super-secret-token"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:rekindle, :redact_values, previous),
        else: Application.delete_env(:rekindle, :redact_values)
    end)

    assert {:ok, failure} =
             Failure.new(
               target: :web,
               stage: :execution,
               code: :cargo_failed,
               message: "super-secret-token failed in /home/user/private/source.rs"
             )

    assert failure.message == "<redacted> failed in <redacted-path>"
    refute Failure.render(failure) =~ "super-secret-token"
    refute Jason.encode!(Failure.to_map(failure)) =~ "/home/user"

    unsafe = %{failure | message: "super-secret-token at /tmp/private"}

    outcome =
      Rekindle.Command.run("rekindle.test", [], [switches: [], positionals: 0], fn _ ->
        {:error, unsafe}
      end)

    refute outcome.stderr =~ "super-secret-token"
    refute outcome.stderr =~ "/tmp/private"
  end

  test "rejects stack-like, raw, and oversized public payloads" do
    base = [target: nil, stage: :internal, code: :internal]
    assert {:error, _} = Failure.new(base ++ [message: "stacktrace:\n secret"])
    assert {:error, _} = Failure.new(base ++ [message: <<255, 254>>])
    assert {:error, _} = Failure.new(base ++ [message: String.duplicate("x", 65_537)])

    assert {:error, _} =
             Diagnostic.new(
               target: nil,
               stage: :internal,
               severity: :error,
               code: :internal,
               message: "safe",
               rendered: "** (RuntimeError) leaked"
             )
  end

  test "direct sinks re-sanitize mutated diagnostics and preserve UTF-8 bounds" do
    previous = Application.get_env(:rekindle, :redact_values)
    Application.put_env(:rekindle, :redact_values, ["sink-secret"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:rekindle, :redact_values, previous),
        else: Application.delete_env(:rekindle, :redact_values)
    end)

    {:ok, diagnostic} =
      Diagnostic.new(
        target: :web,
        stage: :execution,
        severity: :error,
        code: :cargo_failed,
        message: "safe"
      )

    mutated = %{diagnostic | message: "sink-secret in /home/user/private.rs"}

    {:ok, failure} =
      Failure.new(
        target: :web,
        stage: :execution,
        code: :cargo_failed,
        message: String.duplicate("界", 3_000),
        diagnostics: [mutated]
      )

    encoded = Jason.encode!(Failure.to_map(failure))
    assert String.valid?(failure.message)
    assert byte_size(failure.message) <= 8_192
    refute encoded =~ "sink-secret"
    refute encoded =~ "/home/user"

    directly_mutated = %{failure | diagnostics: [%{diagnostic | message: <<255>>}]}
    refute Failure.render(directly_mutated) =~ <<255>>
    refute Jason.encode!(Failure.to_map(directly_mutated)) =~ <<255>>
  end
end
