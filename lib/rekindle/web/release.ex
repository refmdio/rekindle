defmodule Rekindle.Web.Release do
  @moduledoc false

  require Logger

  alias Rekindle.Build.Result
  alias Rekindle.Publication
  alias Rekindle.OwnedPath
  alias Rekindle.Web.{Error, Manifest}

  @retained 2
  @generation ~r/\A[0-9a-f]{64}\z/

  @spec publish(Rekindle.Config.t(), Result.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def publish(
        project,
        %Result{target: :web, profile: :release, metadata: metadata} = result
      ) do
    source = Path.dirname(metadata.manifest)
    namespace = Path.join(project.public_dir, "rekindle")

    with :ok <- validate_source(project, source),
         {:ok, manifest} <- read_manifest(source),
         :ok <- Manifest.validate(source, manifest),
         true <- manifest["generation"] == metadata.generation do
      with_lock(project, fn -> publish_locked(project, namespace, source, manifest, result) end)
    else
      false ->
        error(:invalid_manifest, "Web release generation does not match its manifest")

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp publish_locked(project, namespace, source, manifest, result) do
    destination = Path.join([namespace, "web", manifest["generation"]])

    with {:ok, previous} <- selected_generation(Path.join(namespace, "entry.js")),
         :ok <- cleanup(project, namespace, manifest["generation"], previous),
         {:ok, published?} <- publish_generation(project, source, destination, manifest) do
      finish_publication(
        project,
        namespace,
        destination,
        manifest,
        result,
        published?
      )
    end
  end

  defp finish_publication(project, namespace, destination, manifest, result, published?) do
    with :ok <- select(project, namespace, manifest) do
      {:ok,
       %{
         result
         | artifact: Path.join(destination, manifest["entry"]),
           metadata: %{result.metadata | manifest: Path.join(destination, "manifest.json")}
       }}
    else
      {:error, %Error{} = error} ->
        if published?, do: remove(project, destination)
        {:error, error}
    end
  end

  defp publish_generation(project, source, destination, manifest) do
    case File.lstat(destination) do
      {:ok, %{type: :directory}} ->
        with :ok <- validate_deployment(destination, manifest) do
          {:ok, false}
        end

      {:ok, _stat} ->
        error(:publish, "Web release generation path is not a directory: #{destination}")

      {:error, :enoent} ->
        publish_new_generation(project, source, destination, manifest)

      {:error, reason} ->
        file_error(:publish, destination, reason)
    end
  end

  defp publish_new_generation(project, source, destination, manifest) do
    parent = Path.dirname(destination)

    with :ok <- owned_directory(project, parent),
         {:ok, temporary} <- Publication.temporary_directory(parent) do
      try do
        with :ok <- copy_directory(project, source, temporary),
             :ok <- validate_generation(temporary, manifest),
             :ok <- owned_directory(project, parent),
             :ok <- File.rename(temporary, destination) do
          {:ok, true}
        else
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> file_error(:publish, destination, reason)
        end
      after
        OwnedPath.remove_directory(project.root, temporary)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> file_error(:publish, destination, reason)
    end
  end

  defp validate_generation(root, expected) do
    validate_generation(root, expected, &Manifest.validate/2)
  end

  defp validate_deployment(root, expected) do
    validate_generation(root, expected, &Manifest.validate_deployment/2)
  end

  defp validate_generation(root, expected, validator) do
    with {:ok, stored} <- read_manifest(root),
         true <- stored == expected,
         :ok <- validator.(root, stored) do
      :ok
    else
      false ->
        error(:invalid_manifest, "published Web manifest does not match its generation")

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp copy_directory(project, source, destination) do
    with :ok <- owned_directory(project, destination),
         {:ok, names} <- File.ls(source) do
      Enum.reduce_while(Enum.sort(names), :ok, fn name, :ok ->
        from = Path.join(source, name)
        to = Path.join(destination, name)

        case File.lstat(from) do
          {:ok, %{type: :directory}} ->
            case copy_directory(project, from, to) do
              :ok -> {:cont, :ok}
              {:error, %Error{} = error} -> {:halt, {:error, error}}
            end

          {:ok, %{type: :regular}} ->
            case File.cp(from, to) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, file_error(:publish, to, reason)}
            end

          {:ok, _stat} ->
            {:halt, error(:publish, "Web release member is not a regular file: #{from}")}

          {:error, reason} ->
            {:halt, file_error(:publish, from, reason)}
        end
      end)
    else
      {:error, reason} when is_atom(reason) -> file_error(:publish, source, reason)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp select(project, namespace, manifest) do
    destination = Path.join(namespace, "entry.js")

    generation = manifest["generation"]
    module = Jason.encode!("./web/#{generation}/#{manifest["entry"]}")

    selector = """
    // Rekindle generation: #{generation}
    import init from #{module};
    await init();
    """

    with :ok <- owned_directory(project, namespace),
         {:ok, temporary} <- Publication.temporary_file(namespace, ".tmp-entry-") do
      try do
        with :ok <- File.write(temporary, selector),
             :ok <- owned_directory(project, namespace),
             :ok <- File.rename(temporary, destination) do
          :ok
        else
          {:error, reason} -> file_error(:selector_write, destination, reason)
        end
      after
        OwnedPath.remove_file(project.root, temporary)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> file_error(:selector_write, destination, reason)
    end
  end

  defp with_lock(project, function) do
    case Publication.with_lock(project.root, :web_release, function) do
      {:error, {:publication_lock, reason}} ->
        error(:publication_lock, "cannot serialize Web release publication: #{inspect(reason)}")

      result ->
        result
    end
  end

  defp cleanup(project, namespace, selected, previous) do
    root = Path.join(namespace, "web")

    case OwnedPath.validate_directory(project.root, root) do
      :ok ->
        with {:ok, generations} <- generation_directories(root) do
          retained =
            generations
            |> Enum.sort_by(fn {_path, modified} -> modified end, :desc)
            |> keep(selected, previous)

          stale =
            generations
            |> Enum.map(&elem(&1, 0))
            |> Enum.reject(&MapSet.member?(retained, &1))

          with :ok <- remove_generations(project, stale) do
            remove_temporaries(project, root)
            :ok
          end
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        file_error(:cleanup, root, reason)
    end
  end

  defp generation_directories(root) do
    with {:ok, names} <- File.ls(root) do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, generations} ->
        if Regex.match?(@generation, name) do
          path = Path.join(root, name)

          case File.lstat(path, time: :posix) do
            {:ok, %{type: :directory, mtime: modified}} ->
              {:cont, {:ok, [{path, modified} | generations]}}

            {:ok, _stat} ->
              {:halt, error(:cleanup, "Web release generation path is not a directory: #{path}")}

            {:error, reason} ->
              {:halt, file_error(:cleanup, path, reason)}
          end
        else
          {:cont, {:ok, generations}}
        end
      end)
    else
      {:error, reason} ->
        file_error(:cleanup, root, reason)
    end
  end

  defp keep(generations, selected, previous) do
    preferred_names =
      [selected, previous]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    preferred =
      preferred_names
      |> Enum.flat_map(fn name ->
        Enum.filter(generations, &(Path.basename(elem(&1, 0)) == name))
      end)

    recent =
      generations
      |> Enum.reject(&(&1 in preferred))
      |> Enum.take(max(@retained - length(preferred_names), 0))

    (preferred ++ recent)
    |> MapSet.new(&elem(&1, 0))
  end

  defp remove_temporaries(project, root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, ".tmp-"))
        |> Enum.each(fn name -> remove(project, Path.join(root, name)) end)

      _error ->
        :ok
    end
  end

  defp remove_generations(project, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case OwnedPath.remove_directory(project.root, path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, file_error(:cleanup, path, reason)}
      end
    end)
  end

  defp selected_generation(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        with {:ok, contents} <- File.read(path),
             {:ok, generation} <- parse_selector(contents) do
          {:ok, generation}
        else
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> file_error(:cleanup, path, reason)
        end

      {:ok, _stat} ->
        error(:cleanup, "Web release selector is not a regular file: #{path}")

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        file_error(:cleanup, path, reason)
    end
  end

  defp parse_selector(contents) do
    with [generation, encoded_module] <-
           Regex.run(
             ~r/\A\/\/ Rekindle generation: ([0-9a-f]{64})\nimport init from (.+);\nawait init\(\);\n\z/,
             contents,
             capture: :all_but_first
           ),
         {:ok, module} when is_binary(module) <- Jason.decode(encoded_module),
         true <- Jason.encode!(module) == encoded_module,
         {:ok, _entry} <- selector_entry(module, generation) do
      {:ok, generation}
    else
      _error -> error(:cleanup, "Web release selector is invalid")
    end
  end

  defp selector_entry(module, generation) do
    prefix = "./web/#{generation}/"

    if String.starts_with?(module, prefix) do
      entry = String.replace_prefix(module, prefix, "")
      root = "/generation"
      expanded = Path.expand(entry, root)

      if entry != "" and
           Path.type(entry) == :relative and
           expanded != root and
           String.starts_with?(expanded, root <> "/") and
           Path.relative_to(expanded, root) == entry do
        {:ok, entry}
      else
        :error
      end
    else
      :error
    end
  end

  defp read_manifest(root) do
    path = Path.join(root, "manifest.json")

    with {:ok, contents} <- File.read(path),
         {:ok, manifest} <- Jason.decode(contents) do
      {:ok, manifest}
    else
      {:error, %Jason.DecodeError{} = error} ->
        error(:invalid_manifest, "Web release manifest is invalid: #{Exception.message(error)}")

      {:error, reason} ->
        file_error(:manifest_read, path, reason)
    end
  end

  defp validate_source(project, source) do
    case OwnedPath.validate_directory(project.root, source) do
      :ok -> :ok
      {:error, reason} -> file_error(:manifest_read, source, reason)
    end
  end

  defp owned_directory(project, path) do
    case OwnedPath.ensure_directory(project.root, path) do
      :ok -> :ok
      {:error, reason} -> file_error(:mkdir, path, reason)
    end
  end

  defp remove(project, path) do
    case OwnedPath.remove_directory(project.root, path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("could not remove #{path}: #{OwnedPath.format_error(reason)}")
    end
  end

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{OwnedPath.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
