defmodule Rekindle.Failure do
  @moduledoc "The sole closed, versioned public failure value."

  alias Rekindle.{ConfigError, Diagnostic}

  @groups %{
    configuration:
      ~w[config_missing config_invalid target_undeclared path_invalid path_overlap install_conflict]a,
    compatibility:
      ~w[tool_missing tool_version_mismatch helper_missing helper_checksum_mismatch helper_protocol_mismatch unsupported_host unqualified_tuple]a,
    project_model:
      ~w[cargo_metadata_failed package_not_found target_not_found target_ambiguous feature_invalid lockfile_required]a,
    execution:
      ~w[spawn_failed io_failed cargo_failed cargo_protocol build_timeout cancelled cleanup_unconfirmed output_limit]a,
    web_toolchain:
      ~w[bindgen_failed wasm_schema_mismatch web_graph_invalid unsupported_import asset_collision]a,
    artifact:
      ~w[artifact_missing artifact_ambiguous artifact_changed manifest_invalid seal_failed cache_corrupt generation_limit]a,
    activation:
      ~w[browser_protocol browser_disconnected browser_runtime_failed native_not_ready native_exited handoff_failed]a,
    production:
      ~w[projection_busy projection_invalid digest_failed digest_output_invalid foreign_projection_change release_not_ready]a,
    internal: ~w[contract_violation unexpected_state internal]a
  }

  @retryable_codes ~w[spawn_failed io_failed build_timeout cancelled browser_disconnected native_not_ready projection_busy]a

  @enforce_keys [:target, :stage, :code, :message, :diagnostics, :retryable?]
  defstruct contract_version: 1,
            target: nil,
            stage: nil,
            code: nil,
            message: nil,
            diagnostics: [],
            retryable?: false

  @type stage ::
          :configuration
          | :compatibility
          | :project_model
          | :execution
          | :web_toolchain
          | :artifact
          | :activation
          | :production
          | :internal
  @type code :: atom()
  @type t :: %__MODULE__{
          contract_version: 1,
          target: Rekindle.target() | nil,
          stage: stage(),
          code: code(),
          message: String.t(),
          diagnostics: [Diagnostic.t()],
          retryable?: boolean()
        }

  @allowed_keys ~w[contract_version target stage code message diagnostics retryable?]a

  @spec stages() :: [stage()]
  def stages, do: Map.keys(@groups)

  @spec codes() :: [code()]
  def codes, do: @groups |> Map.values() |> List.flatten()

  @spec stage_for(code()) :: {:ok, stage()} | :error
  def stage_for(code) do
    case Enum.find(@groups, fn {_stage, codes} -> code in codes end) do
      {stage, _codes} -> {:ok, stage}
      nil -> :error
    end
  end

  @spec retryable?(code()) :: boolean()
  def retryable?(code), do: code in @retryable_codes

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, ConfigError.t()}
  def new(attributes) do
    attributes = Map.new(attributes)
    code = Map.get(attributes, :code)

    with :ok <- reject_unknown_keys(attributes),
         {:ok, expected_stage} <- fetch_stage(code),
         :ok <- validate_fields(attributes, expected_stage),
         :ok <- validate_diagnostics(Map.get(attributes, :diagnostics, [])) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(
           %{contract_version: 1, diagnostics: [], retryable?: retryable?(code)},
           attributes
         )
       )}
    end
  rescue
    _ -> error(:config_invalid, "failure attributes are invalid")
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attributes) do
    case new(attributes) do
      {:ok, failure} -> failure
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = failure) do
    %{
      "contract_version" => failure.contract_version,
      "target" => encode_atom(failure.target),
      "stage" => encode_atom(failure.stage),
      "code" => encode_atom(failure.code),
      "message" => failure.message,
      "diagnostics" => Enum.map(failure.diagnostics, &Diagnostic.to_map/1),
      "retryable" => failure.retryable?
    }
  end

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = failure) do
    target = if failure.target, do: "[#{failure.target}] ", else: ""
    "#{target}#{failure.code}: #{failure.message}"
  end

  defp reject_unknown_keys(attributes) do
    case Map.keys(attributes) -- @allowed_keys do
      [] -> :ok
      _ -> error(:config_invalid, "failure contains unknown fields")
    end
  end

  defp fetch_stage(code) do
    case stage_for(code) do
      {:ok, stage} -> {:ok, stage}
      :error -> error(:config_invalid, "failure code is not part of the v1 taxonomy")
    end
  end

  defp validate_fields(attributes, expected_stage) do
    version = Map.get(attributes, :contract_version, 1)
    target = Map.get(attributes, :target)
    stage = Map.get(attributes, :stage)
    code = Map.get(attributes, :code)
    message = Map.get(attributes, :message)
    retryable = Map.get(attributes, :retryable?, retryable?(code))

    if version == 1 and target in [nil, :web, :desktop] and stage == expected_stage and
         safe_message?(message) and retryable == retryable?(code) do
      :ok
    else
      error(:config_invalid, "failure fields do not satisfy the v1 contract")
    end
  end

  defp validate_diagnostics(diagnostics) when is_list(diagnostics) do
    if Enum.all?(diagnostics, &match?(%Diagnostic{}, &1)) do
      :ok
    else
      error(:config_invalid, "failure diagnostics must use Rekindle.Diagnostic")
    end
  end

  defp validate_diagnostics(_diagnostics) do
    error(:config_invalid, "failure diagnostics must be a list")
  end

  defp safe_message?(message) when is_binary(message) do
    String.valid?(message) and message != "" and not String.contains?(message, <<0>>)
  end

  defp safe_message?(_message), do: false

  defp encode_atom(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp encode_atom(value), do: value

  defp error(code, message), do: {:error, ConfigError.new([:failure], code, message)}
end
