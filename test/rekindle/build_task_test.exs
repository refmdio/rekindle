defmodule Rekindle.BuildTaskTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mix.Tasks.Rekindle.Build
  alias Rekindle.{BuildResult, Failure, GenerationRef}

  @digest String.duplicate("c", 64)
  @generation String.duplicate("d", 32)

  test "admits exactly one target and the two explicit build modes" do
    parent = self()

    build = fn otp_app, target, options ->
      send(parent, {:build, otp_app, target, options})
      {:ok, result(target, options[:mode])}
    end

    for {argv, target, mode} <- [
          {["web"], :web, :dev},
          {["desktop"], :desktop, :dev},
          {["web", "--release"], :web, :release},
          {["desktop", "--release", "--json"], :desktop, :release}
        ] do
      outcome = Build.run_outcome(argv, otp_app: :example, build: build)
      assert outcome.exit_status == 0
      assert_receive {:build, :example, ^target, [mode: ^mode]}

      if "--json" in argv do
        assert outcome.stderr == ""
        assert Jason.decode!(outcome.stdout)["result"]["mode"] == Atom.to_string(mode)
      else
        assert outcome.stdout =~ ~s("mode":"#{mode}")
      end
    end
  end

  test "rejects every form outside the command grammar before build dispatch" do
    parent = self()

    build = fn _otp_app, _target, _options ->
      send(parent, :called)
      {:ok, result(:web, :dev)}
    end

    for argv <- [
          [],
          ["all"],
          ["web", "desktop"],
          ["WEB"],
          ["web", "--target", "desktop"],
          ["web", "--release=false"],
          ["web", "--release", "--release"],
          ["web", "--json", "--json"],
          ["--", "web"]
        ] do
      outcome = Build.run_outcome(argv, otp_app: :example, build: build)
      assert outcome.exit_status == 2, inspect(argv)
      refute_received :called
    end
  end

  test "maps typed success, expected failure, invocation failure, and internal failure" do
    success = fn _app, target, options -> {:ok, result(target, options[:mode])} end

    expected = fn _app, target, _options ->
      {:error,
       Failure.new!(
         target: target,
         stage: :execution,
         code: :cargo_failed,
         message: "Cargo failed"
       )}
    end

    internal = fn _app, _target, _options ->
      {:error,
       Failure.new!(
         target: nil,
         stage: :internal,
         code: :contract_violation,
         message: "Invalid handler result"
       )}
    end

    assert Build.run_outcome(["web"], otp_app: :example, build: success).exit_status == 0
    assert Build.run_outcome(["web"], otp_app: :example, build: expected).exit_status == 1
    assert Build.run_outcome(["other"], otp_app: :example, build: success).exit_status == 2

    assert capture_log(fn ->
             assert Build.run_outcome(["web"], otp_app: :example, build: internal).exit_status ==
                      3
           end) =~ "Invalid handler result"

    json = Build.run_outcome(["web", "--json"], otp_app: :example, build: expected)
    assert json.exit_status == 1
    assert json.stderr == ""
    assert Jason.decode!(json.stdout)["result"] == nil
    assert Jason.decode!(json.stdout)["failure"]["code"] == "cargo_failed"
  end

  defp result(target, mode) do
    {:ok, generation} =
      GenerationRef.new(
        target: target,
        support_level: :qualified,
        generation_id: @generation,
        artifact_id: @digest,
        profile: Atom.to_string(mode),
        manifest_digest: @digest
      )

    {:ok, result} =
      BuildResult.new(
        target: target,
        support_level: :qualified,
        mode: mode,
        source_revision: 1,
        build_key: @digest,
        generation: generation,
        duration_ms: 10,
        diagnostics: []
      )

    result
  end
end
