defmodule Rekindle.SealedArtifact.Validation do
  @moduledoc false

  alias Rekindle.{CanonicalValue, Failure, GenerationRef}
  alias Rekindle.SealedArtifact.Identity
  alias Rekindle.SealedArtifact.Producer

  @spec common(map(), GenerationRef.t(), non_neg_integer(), Rekindle.target(), [String.t()]) ::
          {:ok, Producer.t()} | {:error, Failure.t()}
  def common(manifest, generation, source_revision, target, root_keys) do
    with true <- exact?(manifest, root_keys),
         {:ok, generation} <- GenerationRef.new(Map.from_struct(generation)),
         true <- generation.target == target,
         true <- uint?(source_revision),
         true <- manifest["contract_version"] == 1,
         true <- manifest["target"] == Atom.to_string(target),
         {:ok, artifact_id} <- Identity.derive(target, manifest),
         true <- manifest["artifact_id"] == artifact_id,
         true <- manifest["artifact_id"] == generation.artifact_id,
         true <- manifest["manifest_digest"] == generation.manifest_digest,
         true <- manifest["build"]["profile"] == generation.profile,
         {:ok, producer} <- Producer.new(manifest["producer"], target),
         true <- manifest_digest(target, manifest) == generation.manifest_digest do
      {:ok, producer}
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      _ -> invalid(target)
    end
  rescue
    _ -> invalid(target)
  end

  @spec exact?(term(), [String.t()]) :: boolean()
  def exact?(value, keys),
    do: is_map(value) and Map.keys(value) |> Enum.sort() == Enum.sort(keys)

  @spec digest?(term()) :: boolean()
  def digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  @spec uint?(term()) :: boolean()
  def uint?(value), do: is_integer(value) and value in 0..9_007_199_254_740_991

  @spec safe_text?(term(), pos_integer()) :: boolean()
  def safe_text?(value, maximum \\ 512),
    do:
      is_binary(value) and byte_size(value) in 1..maximum and String.printable?(value) and
        not String.contains?(value, [<<0>>, "\n", "\r"])

  @spec relative?(term()) :: boolean()
  def relative?(value) do
    is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value) and
      String.normalize(value, :nfc) == value and not Regex.match?(~r/\p{Cc}/u, value) and
      Path.type(value) == :relative and
      Path.split(value) |> Enum.all?(&(&1 not in ["", ".", ".."])) and
      Path.expand(value, "/") == "/" <> value and not String.contains?(value, "\\")
  end

  @spec sorted_unique?(term(), (term() -> term())) :: boolean()
  def sorted_unique?(values, mapper) when is_list(values),
    do: values == Enum.sort_by(Enum.uniq_by(values, mapper), mapper)

  def sorted_unique?(_values, _mapper), do: false

  @spec fingerprint(map(), reference()) :: String.t()
  def fingerprint(value, token) do
    {union_target, manifest} =
      case value.sealed do
        {:web, %{manifest: manifest}} -> {"web", manifest}
        {:desktop, %{manifest: manifest}} -> {"desktop", manifest}
      end

    canonical = %{
      "target" => Atom.to_string(value.target),
      "source_revision" => value.source_revision,
      "generation_id" => value.generation_id,
      "artifact_id" => value.artifact_id,
      "manifest_digest" => value.manifest_digest,
      "producer" => value.producer.attributes,
      "seal_result" => Atom.to_string(value.seal_result),
      "union_target" => union_target,
      "manifest" => manifest
    }

    :crypto.hash(
      :sha256,
      "rekindle-admitted-seal-v1\0" <>
        CanonicalValue.encode!(canonical) <> :erlang.term_to_binary(token, [:deterministic])
    )
    |> Base.encode16(case: :lower)
  end

  defp manifest_digest(target, manifest) do
    base = Map.delete(manifest, "manifest_digest")

    domain =
      if target == :web, do: "rekindle-web-manifest-v1\0", else: "rekindle-native-manifest-v1\0"

    :crypto.hash(:sha256, domain <> CanonicalValue.encode!(base))
    |> Base.encode16(case: :lower)
  end

  defp invalid(target) do
    {:error,
     Failure.new!(
       target: target,
       stage: :artifact,
       code: :manifest_invalid,
       message: "Sealed artifact contract is invalid"
     )}
  end
end
