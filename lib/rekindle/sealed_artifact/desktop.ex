defmodule Rekindle.SealedArtifact.Desktop do
  @moduledoc false

  alias Rekindle.GenerationRef
  alias Rekindle.SealedArtifact.Validation

  @fields [:generation, :source_revision, :manifest, :producer, :seal_result]
  @enforce_keys @fields
  defstruct @fields

  @root_keys ~w[contract_version rekindle_version application_id target artifact_id build platform producer executable runtime manifest_digest]
  @build_keys ~w[build_key profile package binary features]
  @platform_keys ~w[os arch target_triple]
  @executable_keys ~w[path sha256 size mode]
  @runtime_keys ~w[readiness handoff]

  @type t :: %__MODULE__{
          generation: GenerationRef.t(),
          source_revision: non_neg_integer(),
          manifest: map(),
          producer: Rekindle.SealedArtifact.Producer.t(),
          seal_result: :sealed
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Rekindle.Failure.t()}
  def new(attributes) do
    attributes = Map.new(attributes)

    with true <-
           Map.keys(attributes) |> Enum.sort() ==
             Enum.sort(~w[generation source_revision manifest seal_result]a),
         %GenerationRef{} = generation <- attributes.generation,
         true <- attributes.seal_result == :sealed,
         true <- valid_manifest?(attributes.manifest),
         {:ok, producer} <-
           Validation.common(
             attributes.manifest,
             generation,
             attributes.source_revision,
             :desktop,
             @root_keys
           ) do
      {:ok,
       %__MODULE__{
         generation: generation,
         source_revision: attributes.source_revision,
         manifest: attributes.manifest,
         producer: producer,
         seal_result: :sealed
       }}
    else
      {:error, _} = error -> error
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  defp valid_manifest?(manifest) do
    Validation.safe_text?(manifest["rekindle_version"], 128) and
      Validation.safe_text?(manifest["application_id"], 256) and valid_build?(manifest["build"]) and
      valid_platform?(manifest["platform"]) and valid_executable?(manifest["executable"]) and
      valid_runtime?(manifest["runtime"])
  rescue
    _ -> false
  end

  defp valid_build?(build) do
    Validation.exact?(build, @build_keys) and Validation.digest?(build["build_key"]) and
      Enum.all?(~w[profile package binary], &Validation.safe_text?(build[&1], 256)) and
      Validation.sorted_unique?(build["features"], & &1) and
      Enum.all?(build["features"], &Validation.safe_text?(&1, 256))
  end

  defp valid_platform?(platform),
    do:
      Validation.exact?(platform, @platform_keys) and
        Enum.all?(@platform_keys, &Validation.safe_text?(platform[&1], 256))

  defp valid_executable?(executable),
    do:
      Validation.exact?(executable, @executable_keys) and executable["path"] == "application" and
        Validation.digest?(executable["sha256"]) and Validation.uint?(executable["size"]) and
        executable["mode"] == "executable_owner"

  defp valid_runtime?(runtime),
    do:
      Validation.exact?(runtime, @runtime_keys) and
        runtime["readiness"] in ~w[ipc_v1 startup_grace] and
        runtime["handoff"] in ~w[ipc_v1 disabled] and
        (runtime["readiness"] != "startup_grace" or runtime["handoff"] == "disabled")

  defp invalid do
    {:error,
     Rekindle.Failure.new!(
       target: :desktop,
       stage: :artifact,
       code: :manifest_invalid,
       message: "Desktop sealed artifact is invalid"
     )}
  end
end
