defmodule Rekindle.Redactor do
  @moduledoc false

  alias Rekindle.ConfigError

  @max_input 65_536
  @max_public 8_192
  @unix_path ~r/(?<![A-Za-z0-9_])\/(?:[^\s\x00\/]+\/)*[^\s\x00\/:]+/
  @windows_path ~r/(?i)(?<![A-Za-z0-9_])[A-Z]:\\(?:[^\s\x00\\]+\\)*[^\s\x00\\:]+/
  @stack_markers ["** (", "stacktrace:", "Stack:"]

  @spec sanitize(term()) :: {:ok, String.t()} | {:error, ConfigError.t()}
  def sanitize(value) when is_binary(value) do
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
        redact(value)
    end
  end

  def sanitize(_value), do: error("public text must be a UTF-8 string")

  @spec sanitize!(String.t()) :: String.t()
  def sanitize!(value) do
    case sanitize(value) do
      {:ok, sanitized} -> sanitized
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp redact(value) do
    sanitized =
      :rekindle
      |> Application.get_env(:redact_values, [])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.sort_by(&byte_size/1, :desc)
      |> Enum.reduce(value, &String.replace(&2, &1, "<redacted>"))
      |> String.replace(@windows_path, "<redacted-path>")
      |> String.replace(@unix_path, "<redacted-path>")

    if byte_size(sanitized) <= @max_public do
      {:ok, sanitized}
    else
      suffix = "…<truncated>"
      {:ok, utf8_prefix(sanitized, @max_public - byte_size(suffix)) <> suffix}
    end
  end

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

  defp error(message), do: {:error, ConfigError.new([:public_text], :config_invalid, message)}
end
