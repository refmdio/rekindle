defmodule Rekindle.Cargo.Metadata do
  @moduledoc false

  defmodule Target do
    @moduledoc false
    @enforce_keys [:name, :kind, :crate_types, :src_path]
    defstruct @enforce_keys
  end

  defmodule Package do
    @moduledoc false
    @enforce_keys [:id, :name, :version, :source, :manifest_path, :targets, :features]
    defstruct @enforce_keys
  end

  defmodule Node do
    @moduledoc false
    @enforce_keys [:id, :dependencies]
    defstruct @enforce_keys
  end

  @enforce_keys [
    :workspace_root,
    :target_directory,
    :workspace_members,
    :packages,
    :nodes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec decode(binary(), Rekindle.target() | nil) ::
          {:ok, t()} | {:error, Rekindle.Failure.t()}
  def decode(json, target \\ nil)

  def decode(json, target) when is_binary(json) and target in [nil, :web, :desktop] do
    with true <- byte_size(json) <= 64 * 1_048_576,
         {:ok, value} <- Jason.decode(json),
         {:ok, metadata} <- decode_value(value),
         :ok <- validate_references(metadata) do
      {:ok, metadata}
    else
      _ -> failure(target, "Cargo metadata output is malformed")
    end
  rescue
    _ -> failure(target, "Cargo metadata output is malformed")
  end

  def decode(_json, target),
    do: failure(normalize_target(target), "Cargo metadata output is malformed")

  defp decode_value(%{
         "workspace_root" => workspace_root,
         "target_directory" => target_directory,
         "workspace_members" => workspace_members,
         "packages" => packages,
         "resolve" => %{"nodes" => nodes}
       }) do
    with :ok <- absolute_path(workspace_root),
         :ok <- absolute_path(target_directory),
         {:ok, workspace_members} <- string_list(workspace_members),
         {:ok, packages} <- decode_list(packages, &decode_package/1),
         {:ok, nodes} <- decode_list(nodes, &decode_node/1),
         :ok <- unique(packages, & &1.id),
         :ok <- unique(nodes, & &1.id),
         :ok <- unique_values(workspace_members) do
      {:ok,
       %__MODULE__{
         workspace_root: workspace_root,
         target_directory: target_directory,
         workspace_members: workspace_members,
         packages: packages,
         nodes: nodes
       }}
    end
  end

  defp decode_value(_), do: :error

  defp decode_package(%{
         "id" => id,
         "name" => name,
         "version" => version,
         "source" => source,
         "manifest_path" => manifest_path,
         "targets" => targets,
         "features" => features
       }) do
    with :ok <- safe_string(id, 65_536),
         :ok <- safe_string(name, 255),
         :ok <- safe_string(version, 255),
         :ok <- optional_string(source, 65_536),
         :ok <- absolute_path(manifest_path),
         {:ok, targets} <- decode_list(targets, &decode_target/1),
         {:ok, features} <- feature_map(features) do
      {:ok,
       %Package{
         id: id,
         name: name,
         version: version,
         source: source,
         manifest_path: manifest_path,
         targets: targets,
         features: features
       }}
    end
  end

  defp decode_package(_), do: :error

  defp decode_target(%{
         "name" => name,
         "kind" => kind,
         "crate_types" => crate_types,
         "src_path" => src_path
       }) do
    with :ok <- safe_string(name, 255),
         {:ok, kind} <- string_list(kind),
         {:ok, crate_types} <- string_list(crate_types),
         :ok <- absolute_path(src_path),
         :ok <- unique_values(kind),
         :ok <- unique_values(crate_types) do
      {:ok, %Target{name: name, kind: kind, crate_types: crate_types, src_path: src_path}}
    end
  end

  defp decode_target(_), do: :error

  defp decode_node(%{"id" => id} = node) do
    with :ok <- safe_string(id, 65_536),
         {:ok, dependencies} <- dependencies(node) do
      {:ok, %Node{id: id, dependencies: dependencies |> Enum.uniq() |> Enum.sort()}}
    end
  end

  defp decode_node(_), do: :error

  defp dependencies(%{"deps" => deps}) when is_list(deps) do
    decode_list(deps, fn
      %{"pkg" => package_id} ->
        if safe_string(package_id, 65_536) == :ok, do: {:ok, package_id}, else: :error

      _ ->
        :error
    end)
  end

  defp dependencies(%{"dependencies" => dependencies}), do: string_list(dependencies)
  defp dependencies(_), do: :error

  defp feature_map(features) when is_map(features) do
    Enum.reduce_while(features, {:ok, %{}}, fn
      {name, values}, {:ok, acc} when is_binary(name) ->
        with :ok <- safe_string(name, 255),
             {:ok, values} <- string_list(values),
             :ok <- unique_values(values) do
          {:cont, {:ok, Map.put(acc, name, values)}}
        else
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp feature_map(_), do: :error

  defp validate_references(metadata) do
    package_ids = MapSet.new(metadata.packages, & &1.id)
    node_ids = MapSet.new(metadata.nodes, & &1.id)

    cond do
      not MapSet.subset?(MapSet.new(metadata.workspace_members), package_ids) ->
        :error

      not MapSet.subset?(node_ids, package_ids) ->
        :error

      Enum.any?(metadata.nodes, fn node ->
        not MapSet.subset?(MapSet.new(node.dependencies), package_ids)
      end) ->
        :error

      true ->
        :ok
    end
  end

  defp decode_list(value, decoder) when is_list(value) do
    if proper_list?(value) do
      Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
        case decoder.(item) do
          {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
          _ -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp decode_list(_, _), do: :error

  defp string_list(value) do
    decode_list(value, fn item ->
      if safe_string(item, 65_536) == :ok, do: {:ok, item}, else: :error
    end)
  end

  defp unique(values, mapper) do
    ids = Enum.map(values, mapper)
    unique_values(ids)
  end

  defp unique_values(values) do
    if length(values) == MapSet.size(MapSet.new(values)), do: :ok, else: :error
  end

  defp absolute_path(value) when is_binary(value) do
    if safe_string(value, 65_536) == :ok and Path.type(value) == :absolute and
         Path.expand(value) == value,
       do: :ok,
       else: :error
  end

  defp absolute_path(_), do: :error

  defp optional_string(nil, _max), do: :ok
  defp optional_string(value, max), do: safe_string(value, max)

  defp safe_string(value, max) when is_binary(value) do
    if byte_size(value) in 1..max and String.valid?(value) and
         not String.contains?(value, <<0>>),
       do: :ok,
       else: :error
  end

  defp safe_string(_, _), do: :error
  defp proper_list?(value), do: is_list(value) and :erlang.length(value) >= 0
  defp normalize_target(value) when value in [:web, :desktop], do: value
  defp normalize_target(_), do: nil

  defp failure(target, message) do
    {:error,
     Rekindle.Failure.new!(
       target: target,
       stage: :project_model,
       code: :cargo_metadata_failed,
       message: message
     )}
  end
end
