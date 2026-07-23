defmodule Rekindle.SealedArtifact.Producer do
  @moduledoc false

  alias Rekindle.Failure
  alias Rekindle.SealedArtifact.Compatibility

  @enforce_keys [:kind, :attributes]
  defstruct @enforce_keys

  @type kind :: :canonical_web | :canonical_desktop | :extension
  @type t :: %__MODULE__{kind: kind(), attributes: map()}

  @web_keys ~w[kind rustc cargo rust_target wasm_bindgen integration_identity helper_protocol compatibility_tuple_id]
  @desktop_keys ~w[kind rustc cargo rust_target integration_identity helper_protocol compatibility_tuple_id]
  @extension_keys ~w[kind backend_id backend_version options_digest]

  @spec new(map(), Rekindle.target()) :: {:ok, t()} | {:error, Failure.t()}
  def new(attributes, target) when is_map(attributes) do
    case {target, attributes} do
      {:web, %{"kind" => "canonical_web"}} ->
        canonical(attributes, @web_keys, :canonical_web, :web)

      {:desktop, %{"kind" => "canonical_desktop"}} ->
        canonical(attributes, @desktop_keys, :canonical_desktop, :desktop)

      {target, %{"kind" => "extension"}} when target in [:web, :desktop] ->
        extension(attributes)

      _ ->
        invalid()
    end
  end

  def new(_attributes, _target), do: invalid()

  defp canonical(attributes, keys, kind, target) do
    if exact?(attributes, keys) and digest?(attributes["compatibility_tuple_id"]) and
         Enum.all?(~w[rustc cargo rust_target], &safe_ascii?(attributes[&1])) and
         Compatibility.helper_protocol?(attributes["helper_protocol"]) and
         Compatibility.integration_identity?(attributes["integration_identity"], target) and
         valid_tool?(attributes, target) do
      {:ok, %__MODULE__{kind: kind, attributes: attributes}}
    else
      invalid()
    end
  end

  defp valid_tool?(attributes, :web),
    do: Compatibility.tool_identity?(attributes["wasm_bindgen"], "wasm-bindgen")

  defp valid_tool?(_attributes, :desktop), do: true

  defp extension(attributes) do
    if exact?(attributes, @extension_keys) and safe_identity?(attributes["backend_id"]) and
         safe_ascii?(attributes["backend_version"]) and digest?(attributes["options_digest"]) do
      {:ok, %__MODULE__{kind: :extension, attributes: attributes}}
    else
      invalid()
    end
  end

  defp exact?(value, keys),
    do: is_map(value) and Map.keys(value) |> Enum.sort() == Enum.sort(keys)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp safe_text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.printable?(value) and
        not String.contains?(value, [<<0>>, "\n", "\r"])

  defp safe_identity?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z][a-z0-9_.-]{0,127}\z/, value)

  defp safe_ascii?(value),
    do: safe_text?(value) and value |> :binary.bin_to_list() |> Enum.all?(&(&1 <= 0x7F))

  defp invalid do
    {:error,
     Failure.new!(
       target: nil,
       stage: :artifact,
       code: :manifest_invalid,
       message: "Artifact producer is invalid"
     )}
  end
end
