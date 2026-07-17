defmodule Rekindle.Cargo.Discovery do
  @moduledoc false

  alias Rekindle.Cargo.Metadata
  alias Rekindle.Cargo.Metadata.Package

  defmodule Inventory do
    @moduledoc false
    @enforce_keys [
      :workspace_root,
      :target_directory,
      :selected_package,
      :selected_target,
      :dependency_packages,
      :local_packages,
      :has_local_build_script?
    ]
    defstruct @enforce_keys
  end

  @spec select(Metadata.t(), map()) :: {:ok, Inventory.t()} | {:error, Rekindle.Failure.t()}
  def select(%Metadata{} = metadata, selection) when is_map(selection) do
    target = Map.get(selection, :target)

    with :ok <- selection_shape(selection),
         {:ok, package} <- select_package(metadata, selection.package, target),
         {:ok, cargo_target} <- select_target(package, selection.binary, target),
         :ok <- validate_features(package, selection.features, target),
         {:ok, dependency_packages} <- dependency_closure(metadata, package.id, target) do
      local_packages =
        dependency_packages
        |> Enum.filter(&is_nil(&1.source))
        |> Enum.sort_by(& &1.id)

      {:ok,
       %Inventory{
         workspace_root: metadata.workspace_root,
         target_directory: metadata.target_directory,
         selected_package: package,
         selected_target: cargo_target,
         dependency_packages: Enum.sort_by(dependency_packages, & &1.id),
         local_packages: local_packages,
         has_local_build_script?: Enum.any?(local_packages, &custom_build?/1)
       }}
    end
  end

  def select(_metadata, selection) do
    failure(normalize_target(selection), :cargo_metadata_failed, "Cargo selection is invalid")
  end

  defp selection_shape(%{
         target: target,
         package: package,
         binary: binary,
         rust_target: rust_target,
         profile: profile,
         features: features,
         default_features: default_features
       }) do
    if target in [:web, :desktop] and safe_name?(package) and safe_name?(binary) and
         safe_name?(rust_target) and safe_name?(profile) and is_list(features) and
         proper_list?(features) and Enum.all?(features, &safe_name?/1) and
         features == Enum.sort(Enum.uniq(features)) and is_boolean(default_features),
       do: :ok,
       else: :error
  end

  defp selection_shape(_), do: :error

  defp select_package(metadata, name, target) do
    workspace_members = MapSet.new(metadata.workspace_members)

    case Enum.filter(metadata.packages, fn package ->
           package.name == name and MapSet.member?(workspace_members, package.id)
         end) do
      [package] -> {:ok, package}
      [] -> failure(target, :package_not_found, "Configured Cargo package was not found")
      _ -> failure(target, :cargo_metadata_failed, "Configured Cargo package is ambiguous")
    end
  end

  defp select_target(package, name, target) do
    matching = Enum.filter(package.targets, &(&1.name == name and "bin" in &1.kind))

    case matching do
      [cargo_target] -> {:ok, cargo_target}
      [] -> failure(target, :target_not_found, "Configured Cargo binary target was not found")
      _ -> failure(target, :target_ambiguous, "Configured Cargo binary target is ambiguous")
    end
  end

  defp validate_features(package, features, target) do
    case Enum.reject(features, &Map.has_key?(package.features, &1)) do
      [] -> :ok
      _ -> failure(target, :feature_invalid, "Configured Cargo feature is not declared")
    end
  end

  defp dependency_closure(metadata, root_id, target) do
    packages = Map.new(metadata.packages, &{&1.id, &1})
    nodes = Map.new(metadata.nodes, &{&1.id, &1})

    visit([root_id], MapSet.new(), packages, nodes)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.map(&Map.fetch!(packages, &1))}
      :error -> failure(target, :cargo_metadata_failed, "Cargo dependency graph is incomplete")
    end
  end

  defp visit([], visited, _packages, _nodes), do: {:ok, MapSet.to_list(visited)}

  defp visit([id | rest], visited, packages, nodes) do
    cond do
      MapSet.member?(visited, id) ->
        visit(rest, visited, packages, nodes)

      not Map.has_key?(packages, id) or not Map.has_key?(nodes, id) ->
        :error

      true ->
        dependencies = Map.fetch!(nodes, id).dependencies
        visit(dependencies ++ rest, MapSet.put(visited, id), packages, nodes)
    end
  end

  defp custom_build?(%Package{} = package) do
    Enum.any?(package.targets, &("custom-build" in &1.kind))
  end

  defp safe_name?(value) when is_binary(value) do
    byte_size(value) in 1..255 and String.valid?(value) and
      not String.contains?(value, [<<0>>, "\n", "\r"])
  end

  defp safe_name?(_), do: false
  defp proper_list?(value), do: is_list(value) and :erlang.length(value) >= 0
  defp normalize_target(%{target: value}) when value in [:web, :desktop], do: value
  defp normalize_target(_), do: nil

  defp failure(target, code, message) do
    {:error,
     Rekindle.Failure.new!(
       target: target,
       stage: :project_model,
       code: code,
       message: message
     )}
  end
end
