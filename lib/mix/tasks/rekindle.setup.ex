defmodule Mix.Tasks.Rekindle.Setup do
  @shortdoc "Install and verify Rekindle Rust targets and helper"

  use Mix.Task

  alias Rekindle.{Config, ConfigError, Failure, Setup}
  alias Rekindle.Toolchain.{Helper, Release, TargetInstaller}

  @impl Mix.Task
  def run(argv) do
    argv
    |> run_outcome()
    |> Rekindle.Command.emit_and_exit()
  end

  @doc false
  def run_outcome(argv, overrides \\ []) do
    adapters = [
      load_project: fn -> Config.load(Mix.Project.config()[:app]) |> map_config_error() end,
      ensure_target: &ensure_target/2,
      ensure_helper: &ensure_helper/1
    ]

    Setup.run(argv, Keyword.merge(adapters, overrides))
  end

  defp map_config_error({:ok, project}), do: {:ok, project}

  defp map_config_error({:error, {:invalid_configuration_errors, %ConfigError{}} = invalid}),
    do: {:error, invalid}

  defp map_config_error({:error, [%ConfigError{} = error | _errors]}),
    do: {:error, config_failure(error)}

  defp map_config_error({:error, _errors}),
    do: {:error, fallback_config_failure()}

  defp config_failure(error) do
    code =
      case Failure.stage_for(error.code) do
        {:ok, :configuration} -> error.code
        _ -> :config_invalid
      end

    case Failure.new(
           target: nil,
           stage: :configuration,
           code: code,
           message: error.message
         ) do
      {:ok, failure} -> failure
      {:error, _reason} -> fallback_config_failure()
    end
  end

  defp fallback_config_failure do
    %Failure{
      target: nil,
      stage: :configuration,
      code: :config_invalid,
      message: "configuration admission failed",
      diagnostics: [],
      retryable?: false
    }
  end

  defp ensure_target(target, config), do: TargetInstaller.ensure(target, config)

  defp ensure_helper(source_build?) do
    with {:ok, path} <- Release.ensure(source_build?),
         :ok <- Helper.verify(path, timeout_ms: 5_000) do
      {:ok, path}
    end
  end
end
