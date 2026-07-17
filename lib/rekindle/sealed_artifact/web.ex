defmodule Rekindle.SealedArtifact.Web do
  @moduledoc false

  alias Rekindle.GenerationRef
  alias Rekindle.SealedArtifact.Validation

  @fields [:generation, :source_revision, :manifest, :producer, :seal_result]
  @enforce_keys @fields
  defstruct @fields

  @root_keys ~w[contract_version rekindle_version application_id target artifact_id build producer host_requirements entry hot_styles members edges manifest_digest]
  @build_keys ~w[build_key profile package binary features]
  @host_keys ~w[secure_context webgpu]
  @member_keys ~w[path role sha256 size mime cache source_map]
  @edge_keys ~w[from to kind]
  @roles ~w[bootstrap javascript wasm css asset source_map]
  @caches ~w[no_cache immutable]
  @edge_kinds ~w[esm_import dynamic_import wasm_url source_map css_url asset_url]

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
             :web,
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
      Validation.exact?(manifest["host_requirements"], @host_keys) and
      manifest["host_requirements"] == %{"secure_context" => true, "webgpu" => true} and
      Validation.relative?(manifest["entry"]) and valid_paths?(manifest["hot_styles"]) and
      valid_members?(manifest["members"]) and valid_edges?(manifest["edges"])
  rescue
    _ -> false
  end

  defp valid_build?(build) do
    Validation.exact?(build, @build_keys) and Validation.digest?(build["build_key"]) and
      Enum.all?(~w[profile package binary], &Validation.safe_text?(build[&1], 256)) and
      valid_features?(build["features"])
  end

  defp valid_features?(features),
    do:
      Validation.sorted_unique?(features, & &1) and
        Enum.all?(features, &Validation.safe_text?(&1, 256))

  defp valid_paths?(paths),
    do: Validation.sorted_unique?(paths, & &1) and Enum.all?(paths, &Validation.relative?/1)

  defp valid_members?(members) do
    Validation.sorted_unique?(members, & &1["path"]) and
      Enum.all?(members, fn member ->
        Validation.exact?(member, @member_keys) and Validation.relative?(member["path"]) and
          member["role"] in @roles and Validation.digest?(member["sha256"]) and
          Validation.uint?(member["size"]) and Validation.safe_text?(member["mime"], 256) and
          member["cache"] in @caches and
          (is_nil(member["source_map"]) or Validation.relative?(member["source_map"]))
      end)
  end

  defp valid_edges?(edges) do
    Validation.sorted_unique?(edges, &{&1["from"], &1["to"], &1["kind"]}) and
      Enum.all?(edges, fn edge ->
        Validation.exact?(edge, @edge_keys) and Validation.relative?(edge["from"]) and
          (Validation.relative?(edge["to"]) or https?(edge["to"])) and edge["kind"] in @edge_kinds
      end)
  end

  defp https?(value), do: is_binary(value) and String.starts_with?(value, "https://")

  defp invalid do
    {:error,
     Rekindle.Failure.new!(
       target: :web,
       stage: :artifact,
       code: :manifest_invalid,
       message: "Web sealed artifact is invalid"
     )}
  end
end
