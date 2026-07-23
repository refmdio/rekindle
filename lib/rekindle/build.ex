defmodule Rekindle.Build do
  @moduledoc false

  alias Rekindle.Build.Error
  alias Rekindle.Config

  @profiles [:dev, :release]
  @targets [:web, :desktop]

  @spec run(Config.t(), atom(), keyword()) ::
          {:ok, Rekindle.Build.Result.t()}
          | {:error,
             Error.t()
             | Rekindle.Cargo.Error.t()
             | Rekindle.Desktop.Error.t()
             | Rekindle.Toolchain.Error.t()
             | Rekindle.Web.Error.t()}
  def run(%Config{} = project, target, options) do
    profile = Keyword.get(options, :profile, :dev)

    with :ok <- validate_target(target),
         :ok <- validate_profile(profile),
         {:ok, target_config} <- enabled_target(project, target),
         :ok <- entry_exists(project, target_config) do
      dispatch(project, target_config, profile, options)
    end
  end

  defp validate_target(target) when target in @targets, do: :ok

  defp validate_target(target),
    do: error(:unknown_target, "expected target to be :web or :desktop, got: #{inspect(target)}")

  defp validate_profile(profile) when profile in @profiles, do: :ok

  defp validate_profile(profile),
    do:
      error(:unknown_profile, "expected profile to be :dev or :release, got: #{inspect(profile)}")

  defp enabled_target(project, target) do
    case Map.fetch(project.targets, target) do
      {:ok, target_config} ->
        {:ok, target_config}

      :error ->
        error(
          :disabled_target,
          "#{target} is not enabled; add it to the Rekindle :targets configuration or rerun the installer with --targets"
        )
    end
  end

  defp entry_exists(project, target) do
    path = Path.join(project.root, target.entry)

    if File.regular?(path) do
      :ok
    else
      error(
        :missing_entry,
        "#{target.name} is enabled but #{target.entry} is missing; restore the entry or disable the target"
      )
    end
  end

  defp dispatch(project, %{name: :web} = target, profile, options),
    do: Rekindle.Web.Builder.build(project, target, profile, options)

  defp dispatch(project, target, profile, options),
    do: Rekindle.Desktop.Builder.build(project, target, profile, options)

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
