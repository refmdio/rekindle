defmodule Rekindle.TargetBackend do
  @moduledoc """
  Contract for a trusted backend that replaces one complete target pipeline.

  Backends can plan and finalize a target build, but cannot publish, activate,
  project, or export an artifact directly.
  """

  alias Rekindle.{
    BackendContext,
    CanonicalValue,
    ConfigError,
    Diagnostic,
    ExecutionResult,
    ExternalArtifact,
    ExternalPlan
  }

  alias Rekindle.TargetBackend.CallbackCoordinator

  @id_pattern ~r/\A[a-z][a-z0-9_.-]{0,127}\z/
  @max_plan_entries 1_024
  @max_plan_bytes 1_048_576
  @max_plan_path_bytes 4_096
  @max_config_errors 256
  @max_supplemental_diagnostics 1_024
  @required_callbacks [backend_id: 0, backend_version: 0, validate: 2, plan: 2, finalize: 3]
  @config_diagnostic_codes %{
    invalid_type: :backend_invalid_type,
    invalid_value: :backend_invalid_value,
    unknown_key: :backend_unknown_key,
    missing_key: :backend_missing_key,
    conflict: :backend_conflict
  }

  @callback backend_id() :: String.t()
  @callback backend_version() :: String.t()

  @callback validate(Rekindle.target(), CanonicalValue.t()) ::
              {:ok, normalized_options :: CanonicalValue.t()} | {:error, [ConfigError.t()]}

  @callback plan(BackendContext.t(), CanonicalValue.t()) ::
              {:ok, ExternalPlan.t()} | {:error, Rekindle.Failure.t()}

  @callback finalize(BackendContext.t(), CanonicalValue.t(), ExecutionResult.t()) ::
              {:ok, ExternalArtifact.t()} | {:error, Rekindle.Failure.t()}

  @type admission :: %{
          required(:module) => module(),
          required(:backend_id) => String.t(),
          required(:backend_version) => String.t(),
          required(:options) => CanonicalValue.t(),
          required(:options_digest) => String.t()
        }

  @spec admit(module(), Rekindle.target(), term()) ::
          {:ok, admission()} | {:error, [ConfigError.t()]}
  def admit(module, target, options \\ %{})

  def admit(module, target, options)
      when is_atom(module) and target in [:web, :desktop] do
    with :ok <- ensure_backend(module),
         {:ok, backend_id} <- stable_identity(module, :backend_id, target, &valid_id?/1),
         {:ok, backend_version} <-
           stable_identity(module, :backend_version, target, &valid_version?/1),
         :ok <- ensure_canonical_input(options),
         {:ok, normalized} <- invoke_validate(module, target, options),
         :ok <- ensure_canonical_output(normalized),
         {:ok, digest} <- CanonicalValue.options_digest(normalized) do
      {:ok,
       %{
         module: module,
         backend_id: backend_id,
         backend_version: backend_version,
         options: normalized,
         options_digest: digest
       }}
    else
      {:error, %ConfigError{} = error} -> {:error, [error]}
      {:error, errors} when is_list(errors) -> {:error, errors}
    end
  end

  def admit(_module, _target, _options) do
    {:error,
     [
       ConfigError.from_internal(
         [:backend, :module],
         :config_invalid,
         "backend module must be an existing atom and target must be web or desktop"
       )
     ]}
  end

  @doc false
  @spec validate_plan_result(term()) ::
          {:ok, ExternalPlan.t()} | {:error, ConfigError.t() | Rekindle.Failure.t()}
  def validate_plan_result({:ok, %ExternalPlan{contract_version: 1} = plan}) do
    cond do
      not valid_absolute_path?(plan.executable) ->
        {:error, error([:backend, :plan, :executable], "plan executable must be absolute")}

      not valid_argv?(plan.argv) ->
        {:error, error([:backend, :plan, :argv], "plan argv is invalid")}

      plan.env_mode != :replace or not valid_env_set?(plan.env_set) ->
        {:error,
         error([:backend, :plan, :env_set], "plan must supply a closed replacement environment")}

      plan.diagnostic_mode not in [:opaque, :cargo_json] or
          not (is_integer(plan.timeout_ms) and plan.timeout_ms > 0) ->
        {:error, error([:backend, :plan], "plan diagnostic mode or timeout is invalid")}

      not valid_cwd?(plan.cwd) or not relative_path?(plan.expected_manifest) ->
        {:error, error([:backend, :plan], "plan cwd or expected manifest is invalid")}

      true ->
        {:ok, plan}
    end
  end

  def validate_plan_result({:error, %Rekindle.Failure{} = failure}) do
    validate_failure_arm(failure, :plan)
  end

  def validate_plan_result(_result),
    do: {:error, error([:backend, :plan], "plan/2 returned an invalid union")}

  @doc false
  @spec validate_finalize_result(term()) ::
          {:ok, ExternalArtifact.t()} | {:error, ConfigError.t() | Rekindle.Failure.t()}
  def validate_finalize_result({:ok, %ExternalArtifact{contract_version: 1} = artifact}) do
    with true <- is_binary(artifact.manifest) and relative_path?(artifact.manifest),
         {:ok, diagnostics} <-
           sanitize_supplemental_diagnostics(artifact.supplemental_diagnostics) do
      {:ok, %{artifact | supplemental_diagnostics: diagnostics}}
    else
      _ -> {:error, error([:backend, :finalize], "finalize artifact is invalid")}
    end
  end

  def validate_finalize_result({:error, %Rekindle.Failure{} = failure}) do
    validate_failure_arm(failure, :finalize)
  end

  def validate_finalize_result(_result),
    do: {:error, error([:backend, :finalize], "finalize/3 returned an invalid union")}

  @doc false
  @spec invoke_plan(module(), BackendContext.t(), CanonicalValue.t()) ::
          {:ok, ExternalPlan.t()} | {:error, Rekindle.Failure.t()}
  def invoke_plan(module, %BackendContext{target: target} = context, options) do
    with {:ok, result} <- CallbackCoordinator.invoke(module, :plan, [context, options], target) do
      case validate_plan_result(result) do
        {:ok, %ExternalPlan{} = plan} -> {:ok, plan}
        {:error, %Rekindle.Failure{target: ^target} = failure} -> {:error, failure}
        {:error, %Rekindle.Failure{}} -> CallbackCoordinator.invalid_return(:plan, target)
        {:error, %ConfigError{}} -> CallbackCoordinator.invalid_return(:plan, target)
      end
    end
  end

  @doc false
  @spec invoke_finalize(module(), BackendContext.t(), CanonicalValue.t(), ExecutionResult.t()) ::
          {:ok, ExternalArtifact.t()} | {:error, Rekindle.Failure.t()}
  def invoke_finalize(module, %BackendContext{target: target} = context, options, result) do
    with {:ok, returned} <-
           CallbackCoordinator.invoke(module, :finalize, [context, options, result], target) do
      case validate_finalize_result(returned) do
        {:ok, %ExternalArtifact{} = artifact} -> {:ok, artifact}
        {:error, %Rekindle.Failure{target: ^target} = failure} -> {:error, failure}
        {:error, %Rekindle.Failure{}} -> CallbackCoordinator.invalid_return(:finalize, target)
        {:error, %ConfigError{}} -> CallbackCoordinator.invalid_return(:finalize, target)
      end
    end
  end

  @doc false
  @spec configuration_failure(Rekindle.target(), term()) :: Rekindle.Failure.t()
  def configuration_failure(target, errors) when target in [:web, :desktop] do
    if valid_error_list?(errors) do
      diagnostics =
        Enum.map(errors, fn error ->
          {:ok, diagnostic} =
            Diagnostic.new(
              target: target,
              stage: :configuration,
              severity: :error,
              code: Map.fetch!(@config_diagnostic_codes, error.code),
              message: error.message
            )

          diagnostic
        end)

      Rekindle.Failure.new!(
        target: target,
        stage: :configuration,
        code: :config_invalid,
        message: "extension configuration is invalid",
        diagnostics: diagnostics,
        retryable?: false
      )
    else
      Rekindle.Failure.new!(
        target: target,
        stage: :internal,
        code: :contract_violation,
        message: "extension configuration error contract violation",
        diagnostics: [],
        retryable?: false
      )
    end
  end

  defp ensure_backend(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        case Enum.reject(@required_callbacks, fn {name, arity} ->
               function_exported?(module, name, arity)
             end) do
          [] ->
            :ok

          missing ->
            {:error,
             error([:backend, :module], "backend is missing callbacks: #{inspect(missing)}")}
        end

      {:error, _reason} ->
        {:error, error([:backend, :module], "backend module is not loaded")}
    end
  end

  defp stable_identity(module, callback, target, validator) do
    with {:ok, first} <- CallbackCoordinator.invoke(module, callback, [], target),
         {:ok, second} <- CallbackCoordinator.invoke(module, callback, [], target) do
      cond do
        first != second ->
          {:error,
           error([:backend, callback], "backend identity callback changed during admission")}

        not validator.(first) ->
          {:error, error([:backend, callback], "backend identity has an invalid format")}

        true ->
          {:ok, first}
      end
    else
      {:error, %Rekindle.Failure{} = failure} ->
        {:error, callback_error(callback, failure)}
    end
  end

  defp invoke_validate(module, target, options) do
    case CallbackCoordinator.invoke(module, :validate, [target, options], target) do
      {:ok, {:ok, normalized}} ->
        {:ok, normalized}

      {:ok, {:error, errors}} when is_list(errors) ->
        validate_error_arm(errors)

      {:ok, _other} ->
        {:error, error([:backend, :options], "validate/2 returned an invalid result")}

      {:error, %Rekindle.Failure{} = failure} ->
        {:error, callback_error(:validate, failure)}
    end
  end

  defp callback_error(:validate, failure),
    do: ConfigError.from_internal([:backend, :options], :config_invalid, failure.message)

  defp callback_error(callback, failure),
    do: ConfigError.from_internal([:backend, callback], :config_invalid, failure.message)

  defp ensure_canonical_input(value) do
    case CanonicalValue.validate(value) do
      :ok -> :ok
      {:error, error} -> {:error, %{error | path: ["backend", "options" | error.path]}}
    end
  end

  defp ensure_canonical_output(value) do
    case CanonicalValue.validate(value) do
      :ok ->
        :ok

      {:error, error} ->
        {:error, %{error | path: ["backend", "normalized_options" | error.path]}}
    end
  end

  defp valid_id?(value), do: is_binary(value) and Regex.match?(@id_pattern, value)

  defp valid_version?(value) do
    is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
      Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E))
  end

  defp error(path, message), do: ConfigError.from_internal(path, :config_invalid, message)

  defp validate_error_arm([%ConfigError{} | _] = errors) do
    if valid_error_list?(errors),
      do: {:error, errors},
      else: {:error, invalid_configuration_errors()}
  end

  defp validate_error_arm(_errors),
    do: {:error, invalid_configuration_errors()}

  defp invalid_configuration_errors do
    error([:backend, :options], "extension configuration error contract violation")
  end

  defp error_key(%ConfigError{} = error) do
    {CanonicalValue.encode!(error.path), Atom.to_string(error.code), error.message}
  end

  defp valid_error_list?([%ConfigError{} | _] = errors) do
    proper_list_within?(errors, @max_config_errors) and
      Enum.all?(errors, &ConfigError.valid?/1) and errors == Enum.sort_by(errors, &error_key/1) and
      errors == Enum.uniq_by(errors, &error_key/1)
  end

  defp valid_error_list?(_errors), do: false

  defp validate_failure_arm(failure, callback) do
    case Rekindle.Failure.sanitize(failure) do
      {:ok, sanitized} ->
        {:error, sanitized}

      {:error, _} ->
        {:error,
         error(
           [:backend, callback],
           "#{callback}/#{callback_arity(callback)} returned invalid failure"
         )}
    end
  end

  defp sanitize_supplemental_diagnostics(diagnostics) do
    if proper_list_within?(diagnostics, @max_supplemental_diagnostics) do
      Enum.reduce_while(diagnostics, {:ok, []}, fn
        %Diagnostic{} = diagnostic, {:ok, sanitized} ->
          case Diagnostic.sanitize(diagnostic) do
            {:ok, value} -> {:cont, {:ok, [value | sanitized]}}
            {:error, _reason} -> {:halt, :error}
          end

        _diagnostic, _acc ->
          {:halt, :error}
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp callback_arity(:plan), do: 2
  defp callback_arity(:finalize), do: 3

  defp valid_cwd?(%{root: root, path: path} = cwd) when root in [:project, :client, :staging],
    do: Map.keys(cwd) |> Enum.sort() == [:path, :root] and (path == "." or relative_path?(path))

  defp valid_cwd?(_cwd), do: false

  defp valid_env_set?(entries) when is_list(entries) do
    proper_list_within?(entries, @max_plan_entries) and
      Enum.all?(entries, fn
        %{name: name, value: value, secret: secret?} = entry ->
          Map.keys(entry) |> Enum.sort() == [:name, :secret, :value] and
            is_binary(name) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/, name) and
            valid_plan_string?(value) and is_boolean(secret?)

        _ ->
          false
      end) and
      aggregate_bytes(entries, fn entry ->
        byte_size(entry.name) + byte_size(entry.value)
      end) <= @max_plan_bytes and
      entries == Enum.sort_by(entries, & &1.name) and
      Enum.uniq_by(entries, & &1.name) == entries
  end

  defp valid_env_set?(_entries), do: false

  defp relative_path?(path) do
    is_binary(path) and path != "" and byte_size(path) <= @max_plan_path_bytes and
      String.valid?(path) and String.normalize(path, :nfc) == path and
      Path.type(path) != :absolute and not String.contains?(path, ["\\", <<0>>]) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/, path) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp valid_absolute_path?(path) do
    is_binary(path) and byte_size(path) <= @max_plan_path_bytes and String.valid?(path) and
      Path.type(path) == :absolute and not String.contains?(path, <<0>>) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/, path)
  end

  defp valid_argv?(argv) when is_list(argv) do
    proper_list_within?(argv, @max_plan_entries) and Enum.all?(argv, &valid_plan_string?/1) and
      aggregate_bytes(argv, &byte_size/1) <= @max_plan_bytes
  end

  defp valid_argv?(_argv), do: false

  defp valid_plan_string?(value) do
    is_binary(value) and byte_size(value) <= @max_plan_bytes and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end

  defp aggregate_bytes(values, size) do
    Enum.reduce_while(values, 0, fn value, total ->
      next = total + size.(value)
      if next <= @max_plan_bytes, do: {:cont, next}, else: {:halt, next}
    end)
  end

  defp proper_list_within?(values, limit), do: proper_list_within?(values, limit, 0)
  defp proper_list_within?([], _limit, _count), do: true

  defp proper_list_within?([_value | rest], limit, count) when count < limit,
    do: proper_list_within?(rest, limit, count + 1)

  defp proper_list_within?(_values, _limit, _count), do: false
end
