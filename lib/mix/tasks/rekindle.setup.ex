defmodule Mix.Tasks.Rekindle.Setup do
  @shortdoc "Install and verify Rekindle Rust targets and helper"

  use Mix.Task

  alias Rekindle.{Config, Failure, Setup}
  alias Rekindle.Toolchain.{Release, TargetInstaller}

  @impl Mix.Task
  def run(argv) do
    outcome = run_outcome(argv)
    status = Rekindle.Command.emit(outcome)
    if status != 0, do: Mix.raise("rekindle.setup failed with exit #{status}")
    :ok
  end

  @doc false
  def run_outcome(argv, overrides \\ []) do
    otp_app = Mix.Project.config()[:app]

    adapters = [
      load_project: fn -> Config.load(otp_app) |> map_config_error() end,
      ensure_target: &ensure_target/2,
      ensure_helper: &ensure_helper/1
    ]

    Setup.run(argv, Keyword.merge(adapters, overrides))
  end

  defp map_config_error({:ok, project}), do: {:ok, project}

  defp map_config_error({:error, errors}) do
    {:error,
     Failure.new!(
       target: nil,
       stage: :configuration,
       code: List.first(errors).code,
       message: List.first(errors).message
     )}
  end

  defp ensure_target(target, config), do: TargetInstaller.ensure(target, config)

  defp ensure_helper(source_build?), do: Release.ensure(source_build?)
end
