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
         "generation" => identity(members),
         "entry" => entry,
         "members" => members
       }}
    else
      false -> error(:missing_entry, "wasm-bindgen did not emit #{entry}")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec validate(Path.t(), map()) :: :ok | {:error, Error.t()}
  def validate(root, %{
        "version" => @version,
        "generation" => generation,
        "entry" => entry,
        "members" => members
      })
      when is_binary(generation) and is_binary(entry) and is_list(members) do
    with :ok <- relative_path(entry),
         :ok <- entry_member(entry, members),
         :ok <- validate_members(root, members),
         :ok <- generation_identity(generation, members),
         :ok <- referenced_members(root, members) do
      :ok
    end
  end

  def validate(_root, _manifest),
    do: error(:invalid_manifest, "Web manifest has an unsupported shape")

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
    Enum.reduce_while(members, {:ok, MapSet.new()}, fn member, {:ok, paths} ->
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

  defp validate_member(root, %{"path" => path, "sha256" => expected}, paths)
       when is_binary(expected) do
    with :ok <- relative_path(path),
         false <- MapSet.member?(paths, path),
         {:ok, contents} <- File.read(Path.join(root, path)),
         true <- sha256(contents) == expected do
      {:ok, path}
    else
      true ->
        error(:invalid_manifest, "Web manifest contains duplicate member #{path}")

      {:error, reason} when is_atom(reason) ->
        error(:missing_member, "Web generation member is missing: #{path}")

      false ->
        error(:member_hash, "Web generation member hash does not match: #{path}")

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_member(_root, _member, _paths),
    do: error(:invalid_manifest, "Web manifest contains an invalid member")

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

  defp identity(members), do: members |> Jason.encode!() |> sha256()

  defp entry_member(entry, members) do
    if Enum.any?(members, &(&1["path"] == entry)),
      do: :ok,
      else: error(:invalid_manifest, "Web manifest entry is not a generation member")
  end

  defp generation_identity(generation, members) do
    if generation == identity(members),
      do: :ok,
      else: error(:invalid_manifest, "Web manifest generation does not match its members")
  end

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp file_error(kind, path, reason),
    do: error(kind, "cannot read Web generation member #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
