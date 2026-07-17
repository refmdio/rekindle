defmodule Rekindle.ReloadPlan do
  @moduledoc false

  alias Rekindle.{CanonicalValue, Failure}

  @page_fields ~w[application_id rekindle_version target build producer host_requirements entry]
  @code_roles ~w[bootstrap javascript wasm]
  @closure_edges ~w[css_url asset_url]

  @spec compare(String.t() | nil, map() | nil, map()) ::
          {:ok, map() | nil} | {:error, Failure.t()}
  def compare(applied_id, old, candidate) do
    with :ok <- valid_applied_id(applied_id),
         :ok <- valid_manifest(candidate) do
      candidate_id = candidate["artifact_id"]

      cond do
        applied_id == candidate_id ->
          {:ok, nil}

        is_nil(applied_id) ->
          {:ok, page(nil, candidate_id, "initial")}

        not valid_old?(old, applied_id) ->
          {:ok, page(applied_id, candidate_id, "history_unavailable")}

        true ->
          {:ok, compare_verified(applied_id, old, candidate)}
      end
    else
      _ -> failure()
    end
  end

  defp compare_verified(applied_id, old, candidate) do
    candidate_id = candidate["artifact_id"]
    old_members = index(old["members"], "path")
    new_members = index(candidate["members"], "path")
    changed_members = changed_members(old_members, new_members)
    old_edges = edge_set(old["edges"])
    new_edges = edge_set(candidate["edges"])
    changed_edges = MapSet.symmetric_difference(old_edges, new_edges)

    cond do
      Enum.any?(@page_fields, &(old[&1] != candidate[&1])) or
          code_member_changed?(changed_members, old_members, new_members) ->
        page(applied_id, candidate_id, "code_changed")

      old["hot_styles"] != candidate["hot_styles"] ->
        page(applied_id, candidate_id, "graph_changed")

      true ->
        closure = closure(MapSet.new(candidate["hot_styles"]), old_edges, new_edges)

        cond do
          invalid_changed_edge?(changed_edges, closure) ->
            page(applied_id, candidate_id, "graph_changed")

          undeclared_change?(changed_members, closure, old_edges, new_edges) ->
            page(applied_id, candidate_id, "undeclared_asset")

          true ->
            assets =
              changed_members
              |> Enum.filter(&(MapSet.member?(closure, &1) and candidate_asset?(new_members[&1])))
              |> Enum.sort()

            %{
              "v" => 1,
              "mode" => "static",
              "from_artifact_id" => applied_id,
              "to_artifact_id" => candidate_id,
              "styles" =>
                Enum.map(candidate["hot_styles"], &%{"old_path" => &1, "new_path" => &1}),
              "assets" => assets,
              "reason" => "hot_styles_only"
            }
        end
    end
  end

  defp changed_members(old, new) do
    old
    |> Map.keys()
    |> Kernel.++(Map.keys(new))
    |> Enum.uniq()
    |> Enum.filter(fn path ->
      case {Map.fetch(old, path), Map.fetch(new, path)} do
        {{:ok, left}, {:ok, right}} ->
          CanonicalValue.encode!(left) != CanonicalValue.encode!(right)

        _ ->
          true
      end
    end)
    |> Enum.sort()
  end

  defp code_member_changed?(paths, old, new) do
    Enum.any?(paths, fn path ->
      role(old[path]) in @code_roles or role(new[path]) in @code_roles
    end)
  end

  defp closure(seed, old_edges, new_edges) do
    edges = MapSet.union(old_edges, new_edges)

    next =
      Enum.reduce(edges, seed, fn {from, to, kind}, acc ->
        if kind in @closure_edges and MapSet.member?(acc, from),
          do: MapSet.put(acc, to),
          else: acc
      end)

    if MapSet.equal?(seed, next), do: seed, else: closure(next, old_edges, new_edges)
  end

  defp invalid_changed_edge?(edges, closure) do
    Enum.any?(edges, fn {from, to, kind} ->
      kind not in @closure_edges or not MapSet.member?(closure, from) or
        not MapSet.member?(closure, to)
    end)
  end

  defp undeclared_change?(changed, closure, old_edges, new_edges) do
    Enum.any?(changed, &(not MapSet.member?(closure, &1))) or
      Enum.any?(MapSet.union(old_edges, new_edges), fn {from, to, _kind} ->
        to in changed and MapSet.member?(closure, to) and not MapSet.member?(closure, from)
      end)
  end

  defp candidate_asset?(nil), do: false
  defp candidate_asset?(member), do: member["role"] != "css"
  defp role(nil), do: nil
  defp role(member), do: member["role"]

  defp valid_old?(old, applied_id),
    do: is_map(old) and valid_manifest(old) == :ok and old["artifact_id"] == applied_id

  defp valid_manifest(manifest) when is_map(manifest) do
    required = ["artifact_id", "members", "edges", "hot_styles" | @page_fields]

    cond do
      not Enum.all?(required, &Map.has_key?(manifest, &1)) -> :error
      not sha256?(manifest["artifact_id"]) -> :error
      not is_list(manifest["members"]) or not is_list(manifest["edges"]) -> :error
      not is_list(manifest["hot_styles"]) -> :error
      not valid_members?(manifest["members"]) -> :error
      not valid_edges?(manifest["edges"]) -> :error
      not Enum.all?(manifest["hot_styles"], &relative_path?/1) -> :error
      manifest["hot_styles"] != Enum.uniq(manifest["hot_styles"]) -> :error
      true -> :ok
    end
  end

  defp valid_manifest(_manifest), do: :error

  defp valid_members?(members) do
    Enum.all?(members, fn member ->
      is_map(member) and relative_path?(member["path"]) and is_binary(member["role"]) and
        CanonicalValue.valid?(member)
    end) and unique?(members, & &1["path"])
  end

  defp valid_edges?(edges) do
    Enum.all?(edges, fn edge ->
      is_map(edge) and relative_path?(edge["from"]) and relative_path?(edge["to"]) and
        is_binary(edge["kind"])
    end) and unique?(edges, &{&1["from"], &1["to"], &1["kind"]})
  end

  defp edge_set(edges), do: MapSet.new(edges, &{&1["from"], &1["to"], &1["kind"]})
  defp index(items, key), do: Map.new(items, &{&1[key], &1})
  defp unique?(items, mapper), do: length(items) == items |> Enum.uniq_by(mapper) |> length()

  defp page(from, to, reason) do
    %{
      "v" => 1,
      "mode" => "page",
      "from_artifact_id" => from,
      "to_artifact_id" => to,
      "styles" => [],
      "assets" => [],
      "reason" => reason
    }
  end

  defp valid_applied_id(nil), do: :ok
  defp valid_applied_id(value), do: if(sha256?(value), do: :ok, else: :error)
  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp relative_path?(value) when is_binary(value) do
    segments = String.split(value, "/")

    value != "" and Path.type(value) == :relative and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp relative_path?(_value), do: false

  defp failure do
    {:error,
     Failure.new!(
       target: :web,
       stage: :activation,
       code: :browser_protocol,
       message: "Reload manifests are invalid"
     )}
  end
end
