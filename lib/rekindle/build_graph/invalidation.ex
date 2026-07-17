defmodule Rekindle.BuildGraph.Invalidation do
  @moduledoc false

  alias Rekindle.Failure

  @spec classify(atom(), [Rekindle.target()], keyword()) ::
          {:ok, %{required(Rekindle.target()) => [atom()]}} | {:error, Failure.t()}
  def classify(change, targets, options \\ [])

  def classify(change, targets, options) when is_list(targets) and is_list(options) do
    canonical = Keyword.get(options, :canonical_targets, targets)
    uncertain_target = Keyword.get(options, :target)

    with true <- valid_targets?(targets),
         true <- valid_subset?(canonical, targets) do
      affected =
        case change do
          change
          when change in [
                 :project_input,
                 :rust,
                 :manifest,
                 :toolchain,
                 :configuration,
                 :public_asset
               ] ->
            all_targets(targets, canonical)

          :web_rust ->
            target_pipeline(targets, canonical, :web)

          :desktop_rust ->
            target_pipeline(targets, canonical, :desktop)

          :bootstrap ->
            target_nodes(canonical, :web, [:package_web, :seal_web])

          change when change in [:development, :projection] ->
            %{}

          :uncertain ->
            if uncertain_target in targets,
              do: target_pipeline(targets, canonical, uncertain_target),
              else: :error

          _ ->
            :error
        end

      if affected == :error,
        do: invalid("Watcher change classification is invalid"),
        else: {:ok, affected}
    else
      _ -> invalid("Watcher target classification is invalid")
    end
  end

  def classify(_change, _targets, _options),
    do: invalid("Watcher change classification is invalid")

  @spec normalize_event(term()) :: {:ok, [map()]} | {:error, Failure.t()}
  def normalize_event({kind, path}) when kind in [:created, :modified, :deleted] do
    if relative_path?(path),
      do: {:ok, [%{kind: kind, path: path}]},
      else: invalid("Watcher path is invalid")
  end

  def normalize_event({:renamed, from, to}) do
    if relative_path?(from) and relative_path?(to),
      do: {:ok, [%{kind: :deleted, path: from}, %{kind: :created, path: to}]},
      else: invalid("Watcher rename paths are invalid")
  end

  def normalize_event(_event), do: invalid("Watcher event is invalid")

  defp all_targets(targets, canonical),
    do: Map.new(targets, fn target -> {target, pipeline(canonical, target)} end)

  defp target_nodes(targets, target, nodes),
    do: if(target in targets, do: %{target => nodes}, else: %{})

  defp target_pipeline(targets, canonical, target),
    do: if(target in targets, do: %{target => pipeline(canonical, target)}, else: %{})

  defp pipeline(canonical, :web),
    do:
      if(:web in canonical,
        do: [:cargo_web, :bindgen_web, :package_web, :seal_web],
        else: [:external_web, :seal_web]
      )

  defp pipeline(canonical, :desktop),
    do:
      if(:desktop in canonical,
        do: [:cargo_desktop, :seal_desktop],
        else: [:external_desktop, :seal_desktop]
      )

  defp valid_targets?(targets),
    do:
      targets != [] and targets == Enum.uniq(targets) and
        Enum.all?(targets, &(&1 in [:web, :desktop]))

  defp valid_subset?(subset, targets),
    do: is_list(subset) and subset == Enum.uniq(subset) and Enum.all?(subset, &(&1 in targets))

  defp relative_path?(value) when is_binary(value) do
    segments = String.split(value, "/")

    value != "" and byte_size(value) <= 4_096 and String.valid?(value) and
      String.normalize(value, :nfc) == value and Path.type(value) == :relative and
      not String.contains?(value, ["\\", <<0>>]) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp relative_path?(_value), do: false

  defp invalid(message) do
    {:error,
     Failure.new!(target: nil, stage: :internal, code: :contract_violation, message: message)}
  end
end
