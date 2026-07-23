defmodule Rekindle.TargetBackendStructsTest do
  use ExUnit.Case, async: true

  alias Rekindle.{BackendContext, ExecutionResult, ExternalArtifact, ExternalPlan, QualifiedPath}

  test "closed extension structs expose the normative fields" do
    assert Map.keys(BackendContext.__struct__()) |> Enum.sort() ==
             [
               :__struct__,
               :application_id,
               :backend_id,
               :backend_version,
               :binary,
               :client_root,
               :contract_version,
               :diagnostic_sink,
               :features,
               :graphics_requirement,
               :hot_styles,
               :host_descriptor,
               :host_requirements_digest,
               :integration_identity,
               :limits,
               :options_digest,
               :otp_app,
               :package,
               :profile,
               :project_root,
               :project_session,
               :public_root,
               :rekindle_version,
               :runtime_manifest,
               :source_revision,
               :staging_root,
               :target
             ]
             |> Enum.sort()

    assert Map.keys(ExternalPlan.__struct__()) |> Enum.sort() ==
             [
               :__struct__,
               :argv,
               :contract_version,
               :cwd,
               :diagnostic_mode,
               :env_mode,
               :env_set,
               :executable,
               :expected_manifest,
               :timeout_ms
             ]
             |> Enum.sort()

    assert Map.keys(ExecutionResult.__struct__()) |> Enum.sort() ==
             [
               :__struct__,
               :build_key,
               :cleanup,
               :contract_version,
               :discarded_bytes,
               :duration_ms,
               :exit_code,
               :outcome,
               :signal,
               :stderr_tail,
               :stdout_tail
             ]
             |> Enum.sort()

    assert Map.keys(ExternalArtifact.__struct__()) |> Enum.sort() ==
             [:__struct__, :contract_version, :manifest, :supplemental_diagnostics]

    assert BackendContext.__struct__().contract_version == 1
    assert ExternalPlan.__struct__().contract_version == 1
    assert ExecutionResult.__struct__().contract_version == 1
    assert ExternalArtifact.__struct__().contract_version == 1
  end

  test "qualified paths expose capability handles rather than filesystem paths" do
    path = QualifiedPath.issue(:read)

    refute Map.has_key?(path, :path)
    assert path.access == :read
    assert is_reference(path.token)
  end
end
