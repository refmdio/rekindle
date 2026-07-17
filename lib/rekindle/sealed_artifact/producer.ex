defmodule Rekindle.SealedArtifact.Producer do
  @moduledoc false

  alias Rekindle.Failure

  @enforce_keys [:kind, :attributes]
  defstruct @enforce_keys

  @type kind :: :canonical_web | :canonical_desktop | :extension
  @type t :: %__MODULE__{kind: kind(), attributes: map()}

  @web_keys ~w[kind rustc cargo rust_target wasm_bindgen gpui_revision helper_version helper_protocol compatibility_tuple_id]
  @desktop_keys ~w[kind rustc cargo rust_target gpui_revision helper_version helper_protocol compatibility_tuple_id]
  @extension_keys ~w[kind backend_id backend_version options_digest]

  @spec new(map(), Rekindle.target()) :: {:ok, t()} | {:error, Failure.t()}
  def new(attributes, target) when is_map(attributes) do
    case {target, attributes} do
      {:web, %{"kind" => "canonical_web"}} ->
        canonical(attributes, @web_keys, :canonical_web)

      {:desktop, %{"kind" => "canonical_desktop"}} ->
        canonical(attributes, @desktop_keys, :canonical_desktop)

      {target, %{"kind" => "extension"}} when target in [:web, :desktop] ->
        extension(attributes)

      _ ->
        invalid()
    end
  end

  def new(_attributes, _target), do: invalid()

  defp canonical(attributes, keys, kind) do
    text_keys = keys -- ~w[kind helper_protocol compatibility_tuple_id]

    if exact?(attributes, keys) and attributes["helper_protocol"] == 1 and
         digest?(attributes["compatibility_tuple_id"]) and
         Enum.all?(text_keys, &safe_text?(attributes[&1])) do
      {:ok, %__MODULE__{kind: kind, attributes: attributes}}
    else
      invalid()
    end
  end

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
