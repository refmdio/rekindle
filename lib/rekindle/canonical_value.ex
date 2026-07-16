defmodule Rekindle.CanonicalValue do
  @moduledoc """
  Validates and encodes the closed value domain accepted by target backends.

  Values use RFC 8785 JSON ordering. Numbers are deliberately restricted to
  interoperable integers, so the encoder never needs floating-point number
  canonicalization.
  """

  alias Rekindle.ConfigError

  @min_integer -9_007_199_254_740_991
  @max_integer 9_007_199_254_740_991
  @max_list_items 128
  @digest_domain "rekindle-backend-options-v1\0"

  @type scalar :: nil | boolean() | integer() | String.t()
  @type t :: scalar() | [t()] | %{required(String.t()) => t()}

  @spec validate(term()) :: :ok | {:error, ConfigError.t()}
  def validate(value), do: validate(value, [])

  @spec valid?(term()) :: boolean()
  def valid?(value), do: validate(value) == :ok

  @spec encode(term()) :: {:ok, binary()} | {:error, ConfigError.t()}
  def encode(value) do
    with :ok <- validate(value) do
      {:ok, encode_valid(value)}
    end
  end

  @spec encode!(term()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, encoded} -> encoded
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec options_digest(term()) :: {:ok, binary()} | {:error, ConfigError.t()}
  def options_digest(value) do
    with {:ok, encoded} <- encode(value) do
      {:ok, :crypto.hash(:sha256, [@digest_domain, encoded]) |> Base.encode16(case: :lower)}
    end
  end

  @spec options_digest!(term()) :: binary()
  def options_digest!(value) do
    case options_digest(value) do
      {:ok, digest} -> digest
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate(nil, _path), do: :ok
  defp validate(value, _path) when is_boolean(value), do: :ok

  defp validate(value, _path)
       when is_integer(value) and value >= @min_integer and value <= @max_integer,
       do: :ok

  defp validate(value, path) when is_integer(value) do
    error(path, :integer_out_of_range, "integer is outside the interoperable JSON range")
  end

  defp validate(value, path) when is_binary(value) do
    if String.valid?(value) do
      :ok
    else
      error(path, :invalid_utf8, "string is not valid UTF-8")
    end
  end

  defp validate(value, path) when is_list(value) do
    if proper_list_within?(value, @max_list_items) do
      value
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
        case validate(item, path ++ [index]) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      error(path, :unsupported_value, "list must be bounded and proper")
    end
  end

  defp validate(value, path) when is_map(value) and not is_struct(value) do
    value
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn {key, item}, :ok ->
      cond do
        not is_binary(key) ->
          {:halt, error(path, :invalid_map_key, "map keys must be strings")}

        not String.valid?(key) ->
          {:halt, error(path, :invalid_utf8, "map key is not valid UTF-8")}

        String.normalize(key, :nfc) != key ->
          {:halt, error(path ++ [key], :non_nfc_key, "map keys must be NFC-normalized")}

        true ->
          case validate(item, path ++ [key]) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp validate(value, path) do
    kind =
      cond do
        is_float(value) -> "float"
        is_atom(value) -> "atom"
        is_tuple(value) -> "tuple"
        is_pid(value) -> "pid"
        is_function(value) -> "function"
        is_reference(value) -> "reference"
        is_struct(value) -> "struct"
        true -> "value"
      end

    error(path, :unsupported_value, "#{kind} is not a CanonicalValue")
  end

  defp encode_valid(nil), do: "null"
  defp encode_valid(true), do: "true"
  defp encode_valid(false), do: "false"
  defp encode_valid(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_valid(value) when is_binary(value), do: Jason.encode!(value)

  defp encode_valid(value) when is_list(value) do
    ["[", value |> Enum.map(&encode_valid/1) |> Enum.intersperse(","), "]"]
    |> IO.iodata_to_binary()
  end

  defp encode_valid(value) when is_map(value) do
    members =
      value
      |> Map.to_list()
      |> Enum.sort_by(fn {key, _value} -> utf16_sort_key(key) end)
      |> Enum.map(fn {key, item} -> [Jason.encode!(key), ":", encode_valid(item)] end)
      |> Enum.intersperse(",")

    IO.iodata_to_binary(["{", members, "}"])
  end

  defp utf16_sort_key(value) do
    :unicode.characters_to_binary(value, :utf8, {:utf16, :big})
  end

  defp proper_list_within?(values, limit), do: proper_list_within?(values, limit, 0)
  defp proper_list_within?([], _limit, _count), do: true

  defp proper_list_within?([_value | rest], limit, count) when count < limit,
    do: proper_list_within?(rest, limit, count + 1)

  defp proper_list_within?(_values, _limit, _count), do: false

  defp error(path, code, message) do
    {:error, ConfigError.new(path, code, message)}
  end
end
