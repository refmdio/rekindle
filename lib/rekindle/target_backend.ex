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
    ExecutionResult,
    ExternalArtifact,
    ExternalPlan
  }

  @id_pattern ~r/\A[a-z][a-z0-9_.-]{0,127}\z/
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
      {:error, errors} when is_list(errors) -> {:error, errors}
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
      Enum.all?(:binary.bin_to_list(value), &(&1 <= 0x7F))
  end

  defp error(path, message), do: ConfigError.new(path, :config_invalid, message)
end
