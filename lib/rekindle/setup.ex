defmodule Rekindle.Setup do
  @moduledoc false

  alias Rekindle.{Command, Failure}

  @grammar [
    switches: [target: :string, source_build_helper: :boolean],
    positionals: 0
  ]

  @spec run([String.t()], keyword()) :: Command.Outcome.t()
  def run(argv, adapters) do
    Command.run("rekindle.setup", argv, @grammar, fn invocation ->
      with {:ok, selected} <- selected_target(invocation.options[:target]),
           {:ok, project} <- load_project(adapters),
           {:ok, targets} <- declared_targets(project, selected),
           {:ok, target_results, progress} <- install_targets(adapters, project, targets),
           {:ok, helper_result} <-
             invoke(adapters, :ensure_helper, [invocation.options[:source_build_helper] || false]) do
        {:ok,
         %{
           targets: target_results,
           helper: helper_result,
           source_build_helper: invocation.options[:source_build_helper] || false
         }, progress ++ ["helper verified"]}
      end
    end)
  end

  defp selected_target(nil), do: {:ok, :all}
  defp selected_target("all"), do: {:ok, :all}
  defp selected_target("web"), do: {:ok, :web}
  defp selected_target("desktop"), do: {:ok, :desktop}

  defp selected_target(_value) do
    {:error,
     Failure.new!(
       target: nil,
       stage: :configuration,
       code: :config_invalid,
       message: "--target must be web, desktop, or all"
     )}
  end

  defp declared_targets(project, :all),
    do: {:ok, Enum.filter([:web, :desktop], &Map.has_key?(project.build.targets, &1))}

  defp declared_targets(project, target) do
    if Map.has_key?(project.build.targets, target) do
      {:ok, [target]}
    else
      {:error,
       Failure.new!(
         target: target,
         stage: :configuration,
         code: :target_undeclared,
         message: "selected setup target is not declared"
       )}
    end
  end

  defp install_targets(adapters, project, targets) do
    Enum.reduce_while(targets, {:ok, [], []}, fn target, {:ok, results, progress} ->
      config = Map.fetch!(project.build.targets, target)

      case invoke(adapters, :ensure_target, [target, config]) do
        {:ok, result} ->
          {:cont,
           {:ok, results ++ [%{target: target, status: result}],
            progress ++ ["#{target} target verified"]}}

        {:error, %Failure{} = failure} ->
          {:halt, {:error, failure}}
      end
    end)
  end

  defp load_project(adapters) do
    case invoke(adapters, :load_project, []) do
      {:error, {:invalid_configuration_errors, %Rekindle.ConfigError{}}} ->
        {:error, extension_contract_failure()}

      result ->
        result
    end
  end

  defp invoke(adapters, key, arguments) do
    case Keyword.fetch(adapters, key) do
      {:ok, function} when is_function(function, length(arguments)) -> apply(function, arguments)
      _ -> {:error, internal("setup adapter #{key} is unavailable")}
    end
  end

  defp internal(message) do
    Failure.new!(target: nil, stage: :internal, code: :contract_violation, message: message)
  end

  defp extension_contract_failure do
    Failure.new!(
      target: nil,
      stage: :internal,
      code: :contract_violation,
      message: "extension configuration error contract violation"
    )
  end
end
