defmodule Rekindle.Web.Manifest do
  @moduledoc false

  alias Rekindle.Web.Error

  @version 1

  @spec create(Path.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def create(root, entry) do
    with :ok <- relative_path(entry),
         true <- File.regular?(Path.join(root, entry)),
         {:ok, members} <- members(root),
         :ok <- referenced_members(root, members) do
      {:ok,
       %{
         "version" => @version,
         "generation" => identity(entry, members),
         "entry" => entry,
         "members" => members
       }}
    else
      false -> error(:missing_entry, "wasm-bindgen did not emit #{entry}")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec validate(Path.t(), map()) :: :ok | {:error, Error.t()}
  def validate(root, manifest), do: validate(root, manifest, :canonical)

  @doc false
  @spec validate_deployment(Path.t(), map()) :: :ok | {:error, Error.t()}
  def validate_deployment(root, manifest), do: validate(root, manifest, :deployment)

  defp validate(
         root,
         %{
           "version" => @version,
           "generation" => generation,
           "entry" => entry,
           "members" => members
         } = manifest,
         kind
       )
       when map_size(manifest) == 4 and is_binary(generation) and is_binary(entry) and
              is_list(members) do
    with :ok <- relative_path(entry),
         :ok <- canonical_members(members),
         :ok <- entry_member(entry, members),
         :ok <- validate_members(root, members),
         :ok <- validate_membership(kind, root, members),
         :ok <- generation_identity(generation, entry, members),
         :ok <- referenced_members(root, members) do
      :ok
    end
  end

  defp validate(_root, _manifest, _kind),
    do: error(:invalid_manifest, "Web manifest has an unsupported shape")

  defp canonical_members(members) do
    valid? =
      Enum.all?(members, fn
        %{"path" => path, "sha256" => hash} = member
        when is_binary(path) and is_binary(hash) and map_size(member) == 2 ->
          true

        _member ->
          false
      end)

    if valid? and members == Enum.sort_by(members, & &1["path"]),
      do: :ok,
      else: error(:invalid_manifest, "Web manifest members are not in canonical path order")
  end

  defp members(root) do
    case collect(root, root, []) do
      {:ok, members} -> {:ok, Enum.sort_by(members, & &1["path"])}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp collect(root, directory, members) do
    case File.ls(directory) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), {:ok, members}, fn name, {:ok, collected} ->
          path = Path.join(directory, name)
          relative = Path.relative_to(path, root)

          case File.lstat(path) do
            {:ok, %{type: :directory}} ->
              case collect(root, path, collected) do
                {:ok, nested} -> {:cont, {:ok, nested}}
                {:error, %Error{} = error} -> {:halt, {:error, error}}
              end

            {:ok, %{type: :regular}} ->
              case File.read(path) do
                {:ok, contents} ->
                  {:cont,
                   {:ok, [%{"path" => relative, "sha256" => sha256(contents)} | collected]}}

                {:error, reason} ->
                  {:halt, file_error(:member_read, relative, reason)}
              end

            {:ok, _stat} ->
              {:halt,
               error(
                 :unsupported_member,
                 "Web generation member is not a regular file: #{relative}"
               )}

            {:error, reason} ->
              {:halt, file_error(:member_read, relative, reason)}
          end
        end)

      {:error, reason} ->
        file_error(:member_read, Path.relative_to(directory, root), reason)
    end
  end

  defp validate_members(root, members) do
    with :ok <- generation_root(root) do
      members
      |> Enum.reduce_while({:ok, MapSet.new()}, fn member, {:ok, paths} ->
        case validate_member(root, member, paths) do
          {:ok, path} -> {:cont, {:ok, MapSet.put(paths, path)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, _paths} -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp validate_member(root, %{"path" => path, "sha256" => expected}, paths)
       when is_binary(expected) do
    with :ok <- relative_path(path),
         false <- MapSet.member?(paths, path),
         :ok <- member_ancestors(root, path),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(root, path)),
         {:ok, contents} <- File.read(Path.join(root, path)),
         true <- sha256(contents) == expected do
      {:ok, path}
    else
      true ->
        error(:invalid_manifest, "Web manifest contains duplicate member #{path}")

      {:error, :enoent} ->
        error(:missing_member, "Web generation member is missing: #{path}")

      {:ok, _stat} ->
        error(:unsupported_member, "Web generation member is not a regular file: #{path}")

      {:error, reason} when is_atom(reason) ->
        file_error(:member_read, path, reason)

      false ->
        error(:member_hash, "Web generation member hash does not match: #{path}")

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_member(_root, _member, _paths),
    do: error(:invalid_manifest, "Web manifest contains an invalid member")

  defp generation_root(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        error(:unsupported_member, "Web generation root is not a directory")

      {:error, :enoent} ->
        error(:missing_member, "Web generation root is missing")

      {:error, reason} ->
        file_error(:member_read, ".", reason)
    end
  end

  defp member_ancestors(root, path) do
    path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce_while({:ok, root}, fn component, {:ok, parent} ->
      ancestor = Path.join(parent, component)

      case File.lstat(ancestor) do
        {:ok, %{type: :directory}} ->
          {:cont, {:ok, ancestor}}

        {:ok, _stat} ->
          {:halt,
           error(
             :unsupported_member,
             "Web generation member ancestor is not a directory: #{Path.relative_to(ancestor, root)}"
           )}

        {:error, :enoent} ->
          {:halt, error(:missing_member, "Web generation member is missing: #{path}")}

        {:error, reason} ->
          {:halt, file_error(:member_read, Path.relative_to(ancestor, root), reason)}
      end
    end)
    |> case do
      {:ok, _parent} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_membership(:canonical, root, declared), do: exact_members(root, declared)
  defp validate_membership(:deployment, _root, _declared), do: :ok

  defp exact_members(root, declared) do
    with {:ok, actual} <- members(root) do
      actual_paths =
        actual
        |> Enum.reject(&(&1["path"] == "manifest.json"))
        |> MapSet.new(& &1["path"])

      declared_paths = MapSet.new(declared, & &1["path"])

      if actual_paths == declared_paths,
        do: :ok,
        else: error(:invalid_manifest, "Web manifest does not list every generation member")
    end
  end

  defp referenced_members(root, members) do
    member_paths = MapSet.new(members, & &1["path"])

    members
    |> Enum.filter(&String.ends_with?(&1["path"], ".js"))
    |> Enum.reduce_while(:ok, fn %{"path" => path}, :ok ->
      with {:ok, source} <- File.read(Path.join(root, path)),
           nil <-
             Enum.find(references(source), fn reference ->
               case resolve_reference(path, reference) do
                 {:ok, resolved} -> not MapSet.member?(member_paths, resolved)
                 :error -> true
               end
             end) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, file_error(:member_read, path, reason)}

        missing ->
          {:halt, error(:missing_reference, "#{path} references missing member #{missing}")}
      end
    end)
  end

  defp references(source) do
    import_references =
      ~r/\b(?:import|export)\s+(?:[^"'()]*?\s+from\s+)?["']([^"'?#]+\.(?:js|wasm))(?:[?#][^"']*)?["']|\bimport\s*\(\s*["']([^"'?#]+\.(?:js|wasm))(?:[?#][^"']*)?["']\s*\)/
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()

    url_references =
      ~r/\bnew\s+URL\s*\(\s*["']([^"'?#]+\.wasm)(?:[?#][^"']*)?["']\s*,\s*import\.meta\.url\s*\)/
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()

    (import_references ++ url_references)
    |> Enum.reject(&(&1 == "" or url?(&1)))
    |> Enum.uniq()
  end

  defp url?(value), do: String.starts_with?(value, ["http:", "https:", "data:"])

  defp relative_path(path) when is_binary(path) and path != "" do
    root = "/generation"
    expanded = Path.expand(path, root)
    normalized = Path.relative_to(expanded, root)

    if Path.type(path) == :relative and
         expanded != root and
         String.starts_with?(expanded, root <> "/") and
         normalized == path do
      :ok
    else
      error(:invalid_path, "Web member path must remain relative: #{inspect(path)}")
    end
  end

  defp relative_path(path),
    do: error(:invalid_path, "Web member path must be a non-empty string: #{inspect(path)}")

  defp resolve_reference(source, reference) do
    root = "/generation"
    expanded = Path.expand(reference, Path.join(root, Path.dirname(source)))

    if expanded != root and String.starts_with?(expanded, root <> "/") do
      {:ok, Path.relative_to(expanded, root)}
    else
      :error
    end
  end

  defp identity(entry, members), do: [@version, entry, members] |> Jason.encode!() |> sha256()

  defp entry_member(entry, members) do
    if Enum.any?(members, &(&1["path"] == entry)),
      do: :ok,
      else: error(:invalid_manifest, "Web manifest entry is not a generation member")
  end

  defp generation_identity(generation, entry, members) do
    if generation == identity(entry, members),
      do: :ok,
      else:
        error(
          :invalid_manifest,
          "Web manifest generation does not match its version, entry, and members"
        )
  end

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp file_error(kind, path, reason),
    do: error(kind, "cannot read Web generation member #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
