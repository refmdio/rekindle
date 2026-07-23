defmodule Rekindle.BuildFacade do
  @moduledoc false

  alias Rekindle.{BuildResult, Config, ConfigError, Failure, GenerationRef}

  @handlers %{
    web: Rekindle.Web.TargetHandler,
    desktop: Rekindle.Desktop.TargetHandler
  }

  @spec build(Rekindle.otp_app(), Rekindle.target(), Rekindle.build_mode(), keyword()) ::
          {:ok, BuildResult.t()} | {:error, Failure.t()}
  def build(otp_app, target, mode, options \\ []) do
    with :ok <- validate_request(otp_app, target, mode, options),
         {:ok, project} <- load_project(otp_app, options),
         :ok <- declared(project, target),
         {:ok, handler} <- resolve_handler(target, options),
         result <- invoke(handler, :build, [project, mode]),
         {:ok, result} <- validate_build_result(result, target, mode) do
      {:ok, result}
    end
  end

  @spec current(Rekindle.otp_app(), Rekindle.target(), keyword()) ::
          {:ok, GenerationRef.t()} | :none
  def current(otp_app, target, options \\ []) do
    with :ok <- validate_request(otp_app, target, nil, options),
         {:ok, project} <- load_project(otp_app, options),
         :ok <- declared(project, target),
         {:ok, handler} <- resolve_handler(target, options),
         result <- invoke(handler, :current, [project]),
         {:ok, result} <- validate_current_result(result, target) do
      result
    else
      _failure -> :none
    end
  end

  defp validate_request(otp_app, target, mode, options) do
    allowed = [:handlers, :load_project]

    if is_atom(otp_app) and otp_app not in [nil, true, false] and target in [:web, :desktop] and
         mode in [nil, :dev, :release] and Keyword.keyword?(options) and
         Keyword.keys(options) -- allowed == [] and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) do
      :ok
    else
      {:error, failure(nil, :configuration, :config_invalid, "Build request is invalid")}
    end
  end

  defp load_project(otp_app, options) do
    loader = Keyword.get(options, :load_project, &Config.load/1)

    case loader.(otp_app) do
      {:ok, %Config.Project{} = project} when project.otp_app == otp_app ->
        {:ok, project}

      {:error, [%ConfigError{} = error | _errors]} ->
        {:error, config_failure(error)}

      {:error, {:invalid_configuration_errors, %ConfigError{}}} ->
        {:error, contract_failure("Extension configuration error contract violation")}

      {:error, _errors} ->
        {:error, failure(nil, :configuration, :config_invalid, "Configuration admission failed")}

      _other ->
        {:error, contract_failure("Project loader returned an invalid result")}
    end
  rescue
    _exception -> {:error, contract_failure("Project loader failed")}
  catch
    _kind, _reason -> {:error, contract_failure("Project loader failed")}
  end

  defp declared(project, target) do
    if Map.has_key?(project.build.targets, target),
      do: :ok,
      else:
        {:error,
         failure(target, :configuration, :target_undeclared, "Build target is not declared")}
  end

  defp resolve_handler(target, options) do
    handlers = Keyword.get(options, :handlers, @handlers)

    with true <- is_map(handlers),
         {:ok, handler} <- Map.fetch(handlers, target),
         true <- is_atom(handler),
         {:module, ^handler} <- Code.ensure_loaded(handler),
         true <- function_exported?(handler, :build, 2),
         true <- function_exported?(handler, :current, 1) do
      {:ok, handler}
    else
      _ -> {:error, contract_failure("Target handler is unavailable")}
    end
  end

  defp invoke(handler, function, arguments) do
    apply(handler, function, arguments)
  rescue
    _exception -> {:error, contract_failure("Target handler failed")}
  catch
    _kind, _reason -> {:error, contract_failure("Target handler failed")}
  end

  defp validate_build_result({:ok, %BuildResult{} = result}, target, mode) do
    case BuildResult.new(Map.from_struct(result)) do
      {:ok, %BuildResult{target: ^target, mode: ^mode} = result} -> {:ok, result}
      _ -> {:error, contract_failure("Target handler returned an invalid build result")}
    end
  end

  defp validate_build_result({:error, %Failure{} = failure}, target, _mode) do
    case sanitize_failure(failure) do
      {:error, %Failure{target: failure_target} = failure}
      when failure_target in [nil, target] ->
        {:error, failure}

      _ ->
        {:error, contract_failure("Target handler returned a failure for another target")}
    end
  end

  defp validate_build_result(_result, _target, _mode),
    do: {:error, contract_failure("Target handler returned an invalid build result")}

  defp validate_current_result(:none, _target), do: {:ok, :none}

  defp validate_current_result({:ok, %GenerationRef{} = generation}, target) do
    case GenerationRef.new(Map.from_struct(generation)) do
      {:ok, %GenerationRef{target: ^target} = generation} -> {:ok, {:ok, generation}}
      _ -> {:error, contract_failure("Target handler returned an invalid current generation")}
    end
  end

  defp validate_current_result(_result, _target),
    do: {:error, contract_failure("Target handler returned an invalid current generation")}

  defp sanitize_failure(failure) do
    case Failure.sanitize(failure) do
      {:ok, failure} ->
        {:error, failure}

      {:error, _reason} ->
        {:error, contract_failure("Target handler returned an invalid failure")}
    end
  end

  defp config_failure(error) do
    code =
      case Failure.stage_for(error.code) do
        {:ok, :configuration} -> error.code
        _ -> :config_invalid
      end

    failure(nil, :configuration, code, error.message)
  end

  defp contract_failure(message),
    do: failure(nil, :internal, :contract_violation, message)

  defp failure(target, stage, code, message),
    do: Failure.new!(target: target, stage: stage, code: code, message: message)
end
