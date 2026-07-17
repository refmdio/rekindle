defmodule Rekindle.SealedArtifact.Web do
  @moduledoc false

  alias Rekindle.GenerationRef
  alias Rekindle.SealedArtifact.Validation
  alias Rekindle.SealedArtifact.WebMemberMetadata

  @fields [:generation, :source_revision, :manifest, :producer, :seal_result]
  @enforce_keys @fields
  defstruct @fields

  @root_keys ~w[contract_version rekindle_version application_id target artifact_id build producer host_requirements entry hot_styles members edges manifest_digest]
  @build_keys ~w[build_key profile package binary features]
  @host_keys ~w[secure_context webgpu]
  @member_keys ~w[path role sha256 size mime cache source_map]
  @edge_keys ~w[from to kind]
  @roles ~w[bootstrap javascript wasm css asset source_map]
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
      valid_members?(manifest["members"]) and valid_edges?(manifest["edges"]) and
      complete_closure?(manifest)
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
    Validation.sorted_unique?(members, & &1["path"]) and casefold_unique?(members) and
      Enum.all?(members, fn member ->
        with true <- Validation.exact?(member, @member_keys),
             true <- Validation.relative?(member["path"]),
             true <- member["role"] in @roles,
             {:ok, mime, cache} <-
               WebMemberMetadata.resolve(member["role"], member["path"]),
             true <- member["mime"] == mime,
             true <- member["cache"] == cache,
             true <- Validation.digest?(member["sha256"]),
             true <- Validation.uint?(member["size"]),
             true <- is_nil(member["source_map"]) or Validation.relative?(member["source_map"]) do
          true
        else
          _ -> false
        end
      end)
  end

  defp valid_edges?(edges) do
    Validation.sorted_unique?(edges, &{&1["from"], &1["to"], &1["kind"]}) and
      Enum.all?(edges, fn edge ->
        Validation.exact?(edge, @edge_keys) and Validation.relative?(edge["from"]) and
          (Validation.relative?(edge["to"]) or https?(edge["to"])) and edge["kind"] in @edge_kinds
      end)
  end

  defp complete_closure?(manifest) do
    members = manifest["members"]
    edges = manifest["edges"]
    roles = Map.new(members, &{&1["path"], &1["role"]})
    entry = manifest["entry"]

    bootstrap_edges =
      Enum.filter(edges, &(&1["from"] == entry and &1["kind"] == "dynamic_import"))

    Enum.count(members, &(&1["role"] == "bootstrap")) == 1 and
      roles[entry] == "bootstrap" and member_cache(members, entry) == "no_cache" and
      Enum.any?(members, &(&1["role"] == "javascript")) and
      Enum.any?(members, &(&1["role"] == "wasm")) and
      Enum.all?(manifest["hot_styles"], fn path ->
        roles[path] == "css" and edge?(edges, entry, path, "css_url")
      end) and
      Enum.all?(edges, fn edge ->
        Map.has_key?(roles, edge["from"]) and
          (Map.has_key?(roles, edge["to"]) or https?(edge["to"]))
      end) and
      length(bootstrap_edges) == 1 and
      roles[hd(bootstrap_edges)["to"]] == "javascript" and
      Enum.all?(members, &valid_source_map?(&1, roles, edges)) and
      Enum.all?(members, &required_reference?(&1, edges))
  rescue
    _ -> false
  end

  defp valid_source_map?(%{"path" => path, "source_map" => nil}, _roles, edges),
    do: not Enum.any?(edges, &(&1["from"] == path and &1["kind"] == "source_map"))

  defp valid_source_map?(%{"path" => path, "source_map" => source_map}, roles, edges),
    do:
      roles[source_map] == "source_map" and
        Enum.filter(edges, &(&1["from"] == path and &1["kind"] == "source_map")) == [
          %{"from" => path, "to" => source_map, "kind" => "source_map"}
        ]

  defp required_reference?(%{"path" => path, "role" => "wasm"}, edges),
    do: Enum.any?(edges, &(&1["to"] == path and &1["kind"] == "wasm_url"))

  defp required_reference?(%{"path" => path, "role" => "source_map"}, edges),
    do: Enum.any?(edges, &(&1["to"] == path and &1["kind"] == "source_map"))

  defp required_reference?(_member, _edges), do: true

  defp edge?(edges, from, to, kind),
    do: Enum.any?(edges, &(&1 == %{"from" => from, "to" => to, "kind" => kind}))

  defp member_cache(members, path) do
    case Enum.find(members, &(&1["path"] == path)) do
      %{"cache" => cache} -> cache
      _ -> nil
    end
  end

  defp casefold_unique?(members) do
    folded = Enum.map(members, &casefold(&1["path"]))
    length(folded) == MapSet.size(MapSet.new(folded))
  end

  defp casefold(value),
    do: value |> String.to_charlist() |> :string.casefold() |> List.to_string()

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
