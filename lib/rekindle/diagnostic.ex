defmodule Rekindle.Diagnostic do
  @moduledoc "A closed, versioned public diagnostic value."

  @enforce_keys [:target, :stage, :severity, :code, :message]
  defstruct contract_version: 1,
            target: nil,
            stage: nil,
            severity: nil,
            code: nil,
            message: nil,
            file: nil,
            line: nil,
            column: nil,
            rendered: nil

  @type severity :: :error | :warning | :info
  @type t :: %__MODULE__{
          contract_version: 1,
          target: Rekindle.target() | nil,
          stage: Rekindle.Failure.stage(),
          severity: severity(),
          code: atom(),
          message: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          rendered: String.t() | nil
        }

  @allowed_keys ~w[contract_version target stage severity code message file line column rendered]a

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Rekindle.ConfigError.t()}
  def new(attributes) do
    attributes = Map.new(attributes)

    with :ok <- reject_unknown_keys(attributes),
         {:ok, attributes} <- sanitize_attributes(attributes),
         :ok <- validate_common(attributes),
         :ok <- validate_location(attributes) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(
           %{contract_version: 1, file: nil, line: nil, column: nil, rendered: nil},
           attributes
         )
       )}
    end
  rescue
    _ -> error(:config_invalid, "diagnostic attributes are invalid")
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = diagnostic) do
    diagnostic
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), encode_atom(value)} end)
  end

  defp reject_unknown_keys(attributes) do
    case Map.keys(attributes) -- @allowed_keys do
      [] -> :ok
      _ -> error(:config_invalid, "diagnostic contains unknown fields")
    end
  end

  defp validate_common(attributes) do
    version = Map.get(attributes, :contract_version, 1)
    target = Map.get(attributes, :target)
    stage = Map.get(attributes, :stage)
    severity = Map.get(attributes, :severity)
    code = Map.get(attributes, :code)
    message = Map.get(attributes, :message)
    rendered = Map.get(attributes, :rendered)

    if version == 1 and target in [nil, :web, :desktop] and
         stage in Rekindle.Failure.stages() and severity in [:error, :warning, :info] and
         is_atom(code) and safe_text?(message) and (is_nil(rendered) or safe_text?(rendered)) do
      :ok
    else
      error(:config_invalid, "diagnostic fields do not satisfy the v1 contract")
    end
  end

  defp validate_location(attributes) do
    file = Map.get(attributes, :file)
    line = Map.get(attributes, :line)
    column = Map.get(attributes, :column)

    cond do
      not (is_nil(file) or safe_file?(file)) ->
        error(:path_invalid, "diagnostic file must be project-relative or stably redacted")

      not (is_nil(line) or (is_integer(line) and line > 0)) ->
        error(:config_invalid, "diagnostic line must be a positive integer")

      not (is_nil(column) or (is_integer(column) and column > 0)) ->
        error(:config_invalid, "diagnostic column must be a positive integer")

      not is_nil(column) and is_nil(line) ->
        error(:config_invalid, "diagnostic column requires a line")

      (not is_nil(line) or not is_nil(column)) and is_nil(file) ->
        error(:config_invalid, "diagnostic location requires a file")

      true ->
        :ok
    end
  end

  defp sanitize_attributes(attributes) do
    with {:ok, message} <- Rekindle.Redactor.sanitize(Map.get(attributes, :message)),
         {:ok, rendered} <- sanitize_optional(Map.get(attributes, :rendered)) do
      {:ok, attributes |> Map.put(:message, message) |> Map.put(:rendered, rendered)}
    end
  end

  defp sanitize_optional(nil), do: {:ok, nil}
  defp sanitize_optional(value), do: Rekindle.Redactor.sanitize(value)

  defp safe_file?("<external>"), do: true

  defp safe_file?(file) when is_binary(file) do
    safe_text?(file) and not String.starts_with?(file, ["/", "\\"]) and
      not Regex.match?(~r/\A[A-Za-z]:[\\\/]/, file) and
      Enum.all?(String.split(file, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp safe_file?(_file), do: false

  defp safe_text?(value) when is_binary(value), do: byte_size(value) <= 8_192

  defp safe_text?(_value), do: false

  defp encode_atom(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp encode_atom(value), do: value

  defp error(code, message) do
    {:error, Rekindle.ConfigError.new([:diagnostic], code, message)}
  end
end
