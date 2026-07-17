defmodule Rekindle.GenerationRef do
  @moduledoc "A read-only reference to one sealed generation."

  @fields [:target, :generation_id, :artifact_id, :profile, :manifest_digest]
  @enforce_keys @fields
  defstruct [contract_version: 1] ++ @fields

  @type t :: %__MODULE__{
          contract_version: 1,
          target: Rekindle.target(),
          generation_id: String.t(),
          artifact_id: String.t(),
          profile: String.t(),
          manifest_digest: String.t()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Rekindle.Failure.t()}
  def new(attributes) do
    attributes = Map.new(attributes)
    version = Map.get(attributes, :contract_version, 1)
    attributes = Map.delete(attributes, :contract_version)

    if version == 1 and Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields) and
         attributes.target in [:web, :desktop] and id?(attributes.generation_id) and
         digest?(attributes.artifact_id) and safe_profile?(attributes.profile) and
         digest?(attributes.manifest_digest) do
      {:ok, struct!(__MODULE__, attributes)}
    else
      invalid()
    end
  rescue
    _ -> invalid()
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = value) do
    %{
      "contract_version" => 1,
      "target" => Atom.to_string(value.target),
      "generation_id" => value.generation_id,
      "artifact_id" => value.artifact_id,
      "profile" => value.profile,
      "manifest_digest" => value.manifest_digest
    }
  end

  defp id?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp safe_profile?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        not String.contains?(value, [<<0>>, "\n", "\r"])

  defp invalid do
    {:error,
     Rekindle.Failure.new!(
       target: nil,
       stage: :internal,
       code: :contract_violation,
       message: "Generation reference is invalid"
     )}
  end
end
