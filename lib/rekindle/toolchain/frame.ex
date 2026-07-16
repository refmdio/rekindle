defmodule Rekindle.Toolchain.Frame do
  @moduledoc false

  alias Rekindle.CanonicalValue

  @max_header 65_536
  @max_payload 1_048_576
  @base_keys ~w[v type request_id payload_len]

  @spec encode(map(), binary()) :: {:ok, binary()} | {:error, atom()}
  def encode(header, payload \\ <<>>) when is_map(header) and is_binary(payload) do
    header =
      header
      |> stringify_keys()
      |> Map.put("v", 1)
      |> Map.put("payload_len", byte_size(payload))

    with :ok <- validate_base(header),
         true <- byte_size(payload) <= @max_payload,
         {:ok, encoded} <- CanonicalValue.encode(header),
         true <- byte_size(encoded) <= @max_header do
      {:ok, <<byte_size(encoded)::unsigned-big-32, encoded::binary, payload::binary>>}
    else
      _ -> {:error, :invalid_frame}
    end
  end

  @spec decode(binary()) ::
          {:ok, map(), binary(), binary()} | {:more, non_neg_integer()} | {:error, atom()}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) < 4,
    do: {:more, 4 - byte_size(bytes)}

  def decode(<<header_length::unsigned-big-32, rest::binary>>) do
    cond do
      header_length > @max_header ->
        {:error, :header_too_large}

      byte_size(rest) < header_length ->
        {:more, header_length - byte_size(rest)}

      true ->
        <<header_bytes::binary-size(^header_length), after_header::binary>> = rest

        with {:ok, header} <- Jason.decode(header_bytes),
             true <- is_map(header),
             :ok <- validate_base(header),
             payload_length when payload_length <= @max_payload <- header["payload_len"],
             true <- CanonicalValue.encode!(header) == header_bytes,
             true <- byte_size(after_header) >= payload_length do
          <<payload::binary-size(^payload_length), remaining::binary>> = after_header
          {:ok, header, payload, remaining}
        else
          false -> {:error, :noncanonical_header}
          _ -> {:error, :invalid_frame}
        end
    end
  rescue
    _ -> {:error, :invalid_frame}
  end

  def decode(_bytes), do: {:error, :invalid_frame}

  @spec max_header_bytes() :: pos_integer()
  def max_header_bytes, do: @max_header

  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload

  defp validate_base(header) do
    if Enum.all?(@base_keys, &Map.has_key?(header, &1)) and header["v"] == 1 and
         is_binary(header["type"]) and header["type"] != "" and
         is_binary(header["request_id"]) and
         Regex.match?(~r/\A[0-9a-f]{32}\z/, header["request_id"]) and
         is_integer(header["payload_len"]) and header["payload_len"] >= 0 do
      :ok
    else
      {:error, :invalid_base}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify(value)}
      {key, value} when is_binary(key) -> {key, stringify(value)}
    end)
  end

  defp stringify(value) when is_map(value), do: stringify_keys(value)
  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp stringify(value), do: value
end
