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

  @id_pattern ~r/\A[a-z][a-z0-9_.-]{0,127}\z/
  @max_plan_entries 1_024
  @max_plan_bytes 1_048_576
  @max_plan_path_bytes 4_096
  @max_config_errors 128
  @max_config_error_path 128
  @max_supplemental_diagnostics 1_024
  @required_callbacks [backend_id: 0, backend_version: 0, validate: 2, plan: 2, finalize: 3]

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
         {:ok, backend_id} <- stable_identity(module, :backend_id, &valid_id?/1),
         {:ok, backend_version} <- stable_identity(module, :backend_version, &valid_version?/1),
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
       ConfigError.new(
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

  defp stable_identity(module, callback, validator) do
    first = apply(module, callback, [])
    second = apply(module, callback, [])

    cond do
      first != second ->
        {:error,
         error([:backend, callback], "backend identity callback changed during admission")}

      not validator.(first) ->
        {:error, error([:backend, callback], "backend identity has an invalid format")}

      true ->
        {:ok, first}
    end
  rescue
    _exception -> {:error, error([:backend, callback], "backend identity callback failed")}
  catch
    _kind, _reason -> {:error, error([:backend, callback], "backend identity callback failed")}
  end

  defp invoke_validate(module, target, options) do
    case module.validate(target, options) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, errors} when is_list(errors) -> validate_error_arm(errors)
      _other -> {:error, error([:backend, :options], "validate/2 returned an invalid result")}
    end
  rescue
    _exception -> {:error, error([:backend, :options], "validate/2 failed")}
  catch
    _kind, _reason -> {:error, error([:backend, :options], "validate/2 failed")}
  end

  defp ensure_canonical_input(value) do
    case CanonicalValue.validate(value) do
      :ok -> :ok
      {:error, error} -> {:error, %{error | path: [:backend, :options | error.path]}}
    end
  end

  defp ensure_canonical_output(value) do
    case CanonicalValue.validate(value) do
      :ok -> :ok
      {:error, error} -> {:error, %{error | path: [:backend, :normalized_options | error.path]}}
    end
  end

  defp valid_id?(value), do: is_binary(value) and Regex.match?(@id_pattern, value)

  defp valid_version?(value) do
    is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
      Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E))
  end

  defp error(path, message), do: ConfigError.new(path, :config_invalid, message)

  defp validate_error_arm([%ConfigError{} | _] = errors) do
    if proper_list_within?(errors, @max_config_errors) and
         Enum.all?(errors, &valid_config_error?/1),
       do: {:error, errors},
       else: {:error, error([:backend, :options], "validate/2 returned invalid errors")}
  end

  defp validate_error_arm(_errors),
    do: {:error, error([:backend, :options], "validate/2 returned invalid errors")}

  defp valid_config_error?(%ConfigError{} = value) do
    value.contract_version == 1 and is_list(value.path) and
      proper_list_within?(value.path, @max_config_error_path) and
      Enum.all?(value.path, &valid_path_segment?/1) and is_atom(value.code) and
      is_binary(value.message) and value.message != "" and String.valid?(value.message) and
      byte_size(value.message) <= 8_192
  end

  defp valid_config_error?(_value), do: false

  defp valid_path_segment?(value),
    do: is_atom(value) or is_binary(value) or (is_integer(value) and value >= 0)

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
