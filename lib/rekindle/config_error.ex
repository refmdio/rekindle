defmodule Rekindle.ConfigError do
  @moduledoc "A stable configuration-admission error."

  @codes [:invalid_type, :invalid_value, :unknown_key, :missing_key, :conflict]
  @max_path_segments 32
  @max_segment_bytes 128
  @max_message_bytes 4_096
  @safe_integer 9_007_199_254_740_991

  @enforce_keys [:path, :code, :message]
  defstruct contract_version: 1, path: [], code: :invalid_value, message: nil

  @type code :: :invalid_type | :invalid_value | :unknown_key | :missing_key | :conflict
  @type path_segment :: String.t() | 0..9_007_199_254_740_991

  @type t :: %__MODULE__{
          contract_version: 1,
          path: [path_segment()],
          code: code(),
          message: String.t()
        }

  @spec codes() :: [code()]
  def codes, do: @codes

  @spec new([path_segment()], code(), String.t()) :: t()
  def new(path, code, message) do
    with true <- valid_path?(path),
         true <- code in @codes,
         {:ok, message} <- sanitize_message(message) do
      %__MODULE__{path: path, code: code, message: message}
    else
      _ -> raise ArgumentError, "ConfigError fields do not satisfy the v1 contract"
    end
  end

  @doc false
  @spec from_internal([atom() | String.t() | non_neg_integer()], atom(), String.t()) :: t()
  def from_internal(path, code, message) do
    normalized_path = Enum.map(path, &normalize_internal_segment/1)
    new(normalized_path, normalize_internal_code(code), message)
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{contract_version: 1, path: path, code: code, message: message}) do
    valid_path?(path) and code in @codes and valid_message?(message)
  end

  def valid?(_value), do: false

  defp valid_path?(path) when is_list(path) do
    proper_list?(path) and length(path) <= @max_path_segments and
      Enum.all?(path, &valid_segment?/1)
  end

  defp valid_path?(_path), do: false

  defp valid_segment?(value) when is_integer(value), do: value in 0..@safe_integer

  defp valid_segment?(value) when is_binary(value) do
    byte_size(value) in 1..@max_segment_bytes and String.valid?(value) and
      String.normalize(value, :nfc) == value
  end

  defp valid_segment?(_value), do: false

  defp sanitize_message(message) when is_binary(message) do
    with {:ok, sanitized} <- Rekindle.Redactor.sanitize(message) do
      normalized = String.normalize(sanitized, :nfc)

      if valid_message?(normalized) do
        {:ok, normalized}
      else
        :error
      end
    end
  end

  defp sanitize_message(_message), do: :error

  defp valid_message?(message) when is_binary(message) do
    byte_size(message) in 1..@max_message_bytes and String.valid?(message) and
      String.normalize(message, :nfc) == message and not String.contains?(message, <<0>>) and
      redaction_stable?(message)
  end

  defp valid_message?(_message), do: false

  defp redaction_stable?(message) do
    case Rekindle.Redactor.sanitize(message) do
      {:ok, ^message} -> true
      _ -> false
    end
  end

  defp normalize_internal_segment(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_internal_segment(value) when is_binary(value), do: String.normalize(value, :nfc)
  defp normalize_internal_segment(value), do: value

  defp normalize_internal_code(:config_missing), do: :missing_key
  defp normalize_internal_code(:target_undeclared), do: :missing_key
  defp normalize_internal_code(:path_overlap), do: :conflict
  defp normalize_internal_code(:invalid_map_key), do: :invalid_type
  defp normalize_internal_code(:unsupported_value), do: :invalid_type
  defp normalize_internal_code(:config_invalid), do: :invalid_value
  defp normalize_internal_code(:path_invalid), do: :invalid_value
  defp normalize_internal_code(code) when code in @codes, do: code
  defp normalize_internal_code(_code), do: :invalid_value

  defp proper_list?([]), do: true
  defp proper_list?([_value | rest]), do: proper_list?(rest)
  defp proper_list?(_value), do: false
end
