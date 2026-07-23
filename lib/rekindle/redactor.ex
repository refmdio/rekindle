defmodule Rekindle.Redactor do
  @moduledoc false

  alias Rekindle.ConfigError

  @max_input 65_536
  @max_public 8_192
  @unix_path ~r/(?<![A-Za-z0-9_])\/(?:[^\s\x00\/]+\/)*[^\s\x00\/:]+/
  @windows_path ~r/(?i)(?<![A-Za-z0-9_])[A-Z]:\\(?:[^\s\x00\\]+\\)*[^\s\x00\\:]+/
  @stack_markers ["** (", "stacktrace:", "Stack:"]

  @spec sanitize(term(), [binary()]) :: {:ok, String.t()} | {:error, ConfigError.t()}
  def sanitize(value, values \\ [])

  def sanitize(value, values) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        error("public text is not valid UTF-8")

      byte_size(value) > @max_input ->
        error("public text exceeds the input bound")

      value == "" or String.contains?(value, <<0>>) ->
        error("public text is empty or contains NUL")

      Enum.any?(@stack_markers, &String.contains?(value, &1)) or
          Regex.match?(~r/\n\s+at\s/, value) ->
        error("public text contains stack-like content")

      true ->
        redact(value, values)
    end
  end

  def sanitize(_value, _values), do: error("public text must be a UTF-8 string")

  @spec redact_bytes(binary(), [binary()]) :: {:ok, binary()} | {:error, ConfigError.t()}
  def redact_bytes(value, values \\ [])

  def redact_bytes(value, values) when is_binary(value) and is_list(values) do
    with {:ok, patterns} <- redaction_values(values) do
      {:ok, replace_bytes(value, patterns, [])}
    end
  end

  def redact_bytes(_value, _values),
    do: error("redaction input must be bytes and values must be a list")

  @doc false
  @spec redaction_values([binary()]) :: {:ok, [binary()]} | {:error, ConfigError.t()}
  def redaction_values(values) when is_list(values) do
    if proper_list?(values) and Enum.all?(values, &is_binary/1) do
      patterns =
        (configured_values() ++ values)
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()
        |> Enum.sort_by(&byte_size/1, :desc)

      {:ok, patterns}
    else
      error("redaction values must be a list of byte strings")
    end
  end

  def redaction_values(_values), do: error("redaction values must be a list of byte strings")

  @spec sanitize!(String.t()) :: String.t()
  def sanitize!(value) do
    case sanitize(value) do
      {:ok, sanitized} -> sanitized
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @doc false
  @spec sanitize_bounded(term(), pos_integer(), [binary()]) ::
          {:ok, String.t()} | {:error, ConfigError.t()}
  def sanitize_bounded(value, limit, values \\ [])

  def sanitize_bounded(value, limit, values)
      when is_binary(value) and is_integer(limit) and limit > 0 do
    cond do
      not String.valid?(value) ->
        error("public text is not valid UTF-8")

      value == "" or String.contains?(value, <<0>>) ->
        error("public text is empty or contains NUL")

      Enum.any?(@stack_markers, &String.contains?(value, &1)) or
          Regex.match?(~r/\n\s+at\s/, value) ->
        error("public text contains stack-like content")

      true ->
        with {:ok, redacted} <- redact_bytes(value, values) do
          sanitized =
            redacted
            |> String.replace(@windows_path, "<redacted-path>")
            |> String.replace(@unix_path, "<redacted-path>")

          if byte_size(sanitized) <= limit,
            do: {:ok, sanitized},
            else: error("public text exceeds its byte bound")
        end
    end
  end

  def sanitize_bounded(_value, _limit, _values),
    do: error("public text and byte bound are invalid")

  defp redact(value, values) do
    with {:ok, redacted} <- redact_bytes(value, values) do
      sanitized =
        redacted
        |> String.replace(@windows_path, "<redacted-path>")
        |> String.replace(@unix_path, "<redacted-path>")

      if byte_size(sanitized) <= @max_public do
        {:ok, sanitized}
      else
        suffix = "…<truncated>"
        {:ok, utf8_prefix(sanitized, @max_public - byte_size(suffix)) <> suffix}
      end
    end
  end

  defp replace_bytes(value, [], _acc), do: value

  defp replace_bytes(value, patterns, acc) do
    case first_match(value, patterns) do
      nil ->
        IO.iodata_to_binary(Enum.reverse([value | acc]))

      {position, length} ->
        prefix = binary_part(value, 0, position)
        remaining = binary_part(value, position + length, byte_size(value) - position - length)
        replace_bytes(remaining, patterns, ["<redacted>", prefix | acc])
    end
  end

  defp first_match(value, patterns) do
    Enum.reduce(patterns, nil, fn pattern, selected ->
      case :binary.match(value, pattern) do
        :nomatch -> selected
        match -> earlier_or_longer(match, selected)
      end
    end)
  end

  defp earlier_or_longer(match, nil), do: match

  defp earlier_or_longer({position, length} = match, {selected_position, selected_length}) do
    if position < selected_position or
         (position == selected_position and length > selected_length),
       do: match,
       else: {selected_position, selected_length}
  end

  defp configured_values do
    case Application.get_env(:rekindle, :redact_values, []) do
      values when is_list(values) -> if proper_list?(values), do: values, else: []
      _malformed -> []
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_value | rest]), do: proper_list?(rest)
  defp proper_list?(_improper_tail), do: false

  defp utf8_prefix(value, bytes) do
    value
    |> binary_part(0, bytes)
    |> trim_invalid_suffix()
  end

  defp trim_invalid_suffix(value) do
    if String.valid?(value),
      do: value,
      else: value |> binary_part(0, byte_size(value) - 1) |> trim_invalid_suffix()
  end

  defp error(message),
    do: {:error, ConfigError.from_internal([:public_text], :config_invalid, message)}
end
