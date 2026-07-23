defmodule Rekindle.ProjectSupervisor do
  @moduledoc false

  use Supervisor

  alias Rekindle.{Config, ConfigError, Diagnostic, Failure}

  def start_link(options) do
    otp_app = Keyword.fetch!(options, :otp_app)

    case Config.load(otp_app) do
      {:ok, project} ->
        Supervisor.start_link(__MODULE__, project, name: Keyword.fetch!(options, :name))

      {:error, errors} ->
        {:error, configuration_failure(errors)}
    end
  end

  @impl true
  def init(project) do
    children = [
      {Rekindle.EventBus, otp_app: project.otp_app},
      {Rekindle.RuntimeState, project: project},
      {Rekindle.ProjectSession, project: project}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp configuration_failure(errors) when is_list(errors) and errors != [] do
    if Enum.all?(errors, &ConfigError.valid?/1) do
      code =
        if Enum.any?(errors, &match?(%ConfigError{code: :missing_key}, &1)),
          do: :config_missing,
          else: :config_invalid

      Failure.new!(
        target: nil,
        stage: :configuration,
        code: code,
        message: configuration_message(code),
        diagnostics: Enum.map(errors, &configuration_diagnostic/1)
      )
    else
      contract_failure()
    end
  end

  defp configuration_failure({:invalid_configuration_errors, %ConfigError{}}) do
    Failure.new!(
      target: nil,
      stage: :internal,
      code: :contract_violation,
      message: "extension configuration error contract violation"
    )
  end

  defp configuration_failure(_errors), do: contract_failure()

  defp configuration_diagnostic(%ConfigError{} = error) do
    {:ok, diagnostic} =
      Diagnostic.new(
        target: nil,
        stage: :configuration,
        severity: :error,
        code: error.code,
        message: error.message
      )

    diagnostic
  end

  defp configuration_message(:config_missing), do: "Project configuration is missing"
  defp configuration_message(:config_invalid), do: "Project configuration is invalid"

  defp contract_failure do
    Failure.new!(
      target: nil,
      stage: :internal,
      code: :contract_violation,
      message: "Project configuration loader returned an invalid result"
    )
  end
end
