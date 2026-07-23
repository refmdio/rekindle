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
  @max_uint32 4_294_967_295
  @max_uint64 18_446_744_073_709_551_615

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
    diagnostic = sanitize_for_sink(diagnostic)

    diagnostic
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), encode_atom(value)} end)
  end

  @spec sanitize(t()) :: {:ok, t()} | {:error, Rekindle.ConfigError.t()}
  def sanitize(%__MODULE__{} = diagnostic), do: diagnostic |> Map.from_struct() |> new()

  @doc false
  @spec collect([t()], Rekindle.target() | nil, Rekindle.Failure.stage()) ::
          {:ok, [t()]} | {:error, Rekindle.ConfigError.t()}
  def collect(values, target, stage) when is_list(values) do
    collect(values, target, stage, 0, [], [], :queue.new())
  end

  def collect(_values, _target, _stage),
    do: error(:config_invalid, "failure diagnostics must be a list")

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
         stable_code?(code) and safe_text?(message) and
         byte_size(message) <= 4_096 and
         (is_nil(rendered) or (safe_text?(rendered) and byte_size(rendered) <= 16_384)) do
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

      not (is_nil(line) or positive_uint32?(line)) ->
        error(:config_invalid, "diagnostic line must be a positive integer")

      not (is_nil(column) or positive_uint32?(column)) ->
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
    with {:ok, message} <-
           Rekindle.Redactor.sanitize_bounded(Map.get(attributes, :message), 4_096),
         {:ok, rendered} <- sanitize_optional(Map.get(attributes, :rendered), 16_384) do
      {:ok, attributes |> Map.put(:message, message) |> Map.put(:rendered, rendered)}
    end
  end

  defp sanitize_optional(nil, _limit), do: {:ok, nil}
  defp sanitize_optional(value, limit), do: Rekindle.Redactor.sanitize_bounded(value, limit)

  defp safe_file?("<external>"), do: true

  defp safe_file?(file) when is_binary(file) do
    segments = String.split(file, "/")

    file != "" and byte_size(file) <= 1_024 and String.valid?(file) and
      String.normalize(file, :nfc) == file and Path.type(file) != :absolute and
      not String.contains?(file, ["\\", <<0>>]) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/, file) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp safe_file?(_file), do: false

  defp safe_text?(value) when is_binary(value) do
    value != "" and String.valid?(value) and String.normalize(value, :nfc) == value and
      not Regex.match?(~r/[\x00-\x09\x0B-\x1F\x7F]/, value)
  end

  defp safe_text?(_value), do: false

  defp stable_code?(value) when is_atom(value) and value not in [nil, true, false] do
    value
    |> Atom.to_string()
    |> then(&(byte_size(&1) <= 64 and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, &1)))
  end

  defp stable_code?(_value), do: false

  defp positive_uint32?(value),
    do: is_integer(value) and value > 0 and value <= @max_uint32

  defp collect([], target, stage, count, complete, first, last) do
    cond do
      count <= 256 ->
        {:ok, Enum.reverse(complete)}

      true ->
        with {:ok, marker} <- truncation_marker(target, stage, count - 255) do
          {:ok, Enum.reverse(first) ++ [marker] ++ :queue.to_list(last)}
        end
    end
  end

  defp collect([%__MODULE__{} = value | rest], target, stage, count, complete, first, last)
       when count < @max_uint64 do
    case sanitize(value) do
      {:ok, %{target: ^target, stage: ^stage} = diagnostic} ->
        next = count + 1
        complete = if next <= 256, do: [diagnostic | complete], else: complete
        first = if next <= 127, do: [diagnostic | first], else: first
        last = push_last(last, diagnostic)
        collect(rest, target, stage, next, complete, first, last)

      _ ->
        error(:config_invalid, "failure diagnostic is unsafe or has mismatched attribution")
    end
  end

  defp collect([_value | _rest], _target, _stage, _count, _complete, _first, _last),
    do: error(:config_invalid, "failure diagnostics must use Rekindle.Diagnostic")

  defp collect(_improper, _target, _stage, _count, _complete, _first, _last),
    do: error(:config_invalid, "failure diagnostics must be a proper list")

  defp push_last(queue, value) do
    queue = :queue.in(value, queue)
    if :queue.len(queue) > 128, do: queue |> :queue.drop(), else: queue
  end

  defp truncation_marker(target, stage, discarded) do
    new(
      target: target,
      stage: stage,
      severity: :warning,
      code: :diagnostics_truncated,
      message: "diagnostics omitted",
      rendered: "discarded=#{discarded}"
    )
  end

  defp encode_atom(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp encode_atom(value), do: value

  defp sanitize_for_sink(diagnostic) do
    case sanitize(diagnostic) do
      {:ok, sanitized} ->
        sanitized

      {:error, _} ->
        new!(
          target: nil,
          stage: :internal,
          severity: :error,
          code: :contract_violation,
          message: "unsafe diagnostic payload"
        )
    end
  end

  defp new!(attributes) do
    {:ok, diagnostic} = new(attributes)
    diagnostic
  end

  defp error(code, message) do
    {:error, Rekindle.ConfigError.from_internal([:diagnostic], code, message)}
  end
end
