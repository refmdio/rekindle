defmodule Rekindle.Web.Release do
  @moduledoc false

  alias Rekindle.Build.Result
  alias Rekindle.Publication
  alias Rekindle.Web.{Error, Manifest}

  @retained 2
  @generation ~r/\A[0-9a-f]{32}\z/

  @spec publish(Rekindle.Config.t(), Result.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def publish(
        project,
        %Result{target: :web, profile: :release, metadata: metadata} = result
      ) do
    source = Path.dirname(metadata.manifest)
    namespace = Path.join(project.public_dir, "rekindle")
    previous = selected_generation(namespace)

    with {:ok, manifest} <- Manifest.read(source),
         true <- manifest["generation"] == metadata.generation,
         :ok <- Manifest.validate(source, manifest),
         {:ok, destination} <- publish_generation(namespace, source, manifest),
         :ok <- select(namespace, manifest) do
      cleanup(Path.join(namespace, "web"), [manifest["generation"], previous])

      {:ok,
       %{
         result
         | artifact: Path.join(destination, manifest["entry"]),
           metadata: %{metadata | manifest: Path.join(destination, "manifest.json")}
       }}
    else
      false -> error(:invalid_manifest, "Web release does not match its build manifest")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp publish_generation(namespace, source, manifest) do
    parent = Path.join(namespace, "web")
    destination = Path.join(parent, manifest["generation"])

    case File.stat(destination) do
      {:ok, %{type: :directory}} ->
        with {:ok, stored} <- Manifest.read(destination),
             true <- stored == manifest,
             :ok <- Manifest.validate(destination, stored) do
          {:ok, destination}
        else
          false -> error(:invalid_manifest, "published Web manifest does not match")
          {:error, %Error{} = error} -> {:error, error}
        end

      {:ok, _stat} ->
        error(:publish, "Web release path is not a directory: #{destination}")

      {:error, :enoent} ->
        publish_new_generation(parent, source, destination, manifest)

      {:error, reason} ->
        file_error(:publish, destination, reason)
    end
  end

  defp publish_new_generation(parent, source, destination, manifest) do
    with :ok <- File.mkdir_p(parent),
         {:ok, temporary} <- Publication.temporary_directory(parent) do
      try do
        with :ok <- copy_directory(source, temporary),
             {:ok, stored} <- Manifest.read(temporary),
             true <- stored == manifest,
             :ok <- Manifest.validate(temporary, stored),
             :ok <- File.rename(temporary, destination) do
          {:ok, destination}
        else
          false -> error(:invalid_manifest, "copied Web manifest does not match")
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> file_error(:publish, destination, reason)
        end
      after
        File.rm_rf(temporary)
      end
    else
      {:error, reason} -> file_error(:publish, destination, reason)
    end
  end

  defp copy_directory(source, destination) do
    with {:ok, names} <- File.ls(source) do
      Enum.reduce_while(names, :ok, fn name, :ok ->
        from = Path.join(source, name)
        to = Path.join(destination, name)

        case File.stat(from) do
          {:ok, %{type: :directory}} ->
            with :ok <- File.mkdir(to),
                 :ok <- copy_directory(from, to) do
              {:cont, :ok}
            else
              {:error, %Error{} = error} -> {:halt, {:error, error}}
              {:error, reason} -> {:halt, file_error(:publish, to, reason)}
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
      {:error, reason} -> file_error(:publish, source, reason)
    end
  end

  defp select(namespace, manifest) do
    destination = Path.join(namespace, "entry.js")
    generation = manifest["generation"]
    module = Jason.encode!("./web/#{generation}/#{manifest["entry"]}")

    selector = """
    // Rekindle generation: #{generation}
    import init from #{module};
    await init();
    """

    with :ok <- File.mkdir_p(namespace),
         {:ok, temporary} <- Publication.temporary_file(namespace, ".tmp-entry-") do
      try do
        with :ok <- File.write(temporary, selector),
             :ok <- File.rename(temporary, destination) do
          :ok
        else
          {:error, reason} -> file_error(:selector_write, destination, reason)
        end
      after
        File.rm(temporary)
      end
    else
      {:error, reason} -> file_error(:selector_write, destination, reason)
    end
  end

  defp cleanup(root, selected) do
    with {:ok, names} <- File.ls(root) do
      names
      |> Enum.filter(&Regex.match?(@generation, &1))
      |> Enum.map(fn name ->
        path = Path.join(root, name)

        case File.stat(path, time: :posix) do
          {:ok, %{type: :directory, mtime: modified}} -> {path, modified}
          _other -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> retain(selected)
      |> Enum.each(&File.rm_rf/1)
    end

    :ok
  end

  defp retain(generations, selected) do
    selected = selected |> Enum.reject(&is_nil/1) |> Enum.uniq()

    kept =
      selected
      |> Enum.flat_map(fn generation ->
        Enum.filter(generations, &(Path.basename(elem(&1, 0)) == generation))
      end)
      |> then(fn preferred ->
        recent =
          generations
          |> Enum.reject(&(&1 in preferred))
          |> Enum.take(max(@retained - length(preferred), 0))

        preferred ++ recent
      end)
      |> MapSet.new(&elem(&1, 0))

    generations
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&MapSet.member?(kept, &1))
  end

  defp selected_generation(namespace) do
    with {:ok, contents} <- File.read(Path.join(namespace, "entry.js")),
         [generation] <-
           Regex.run(
             ~r/\A\/\/ Rekindle generation: ([0-9a-f]{32})\n/,
             contents,
             capture: :all_but_first
           ) do
      generation
    else
      _error -> nil
    end
  end

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
