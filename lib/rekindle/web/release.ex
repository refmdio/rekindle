defmodule Rekindle.Web.Release do
  @moduledoc false

  require Logger

  alias Rekindle.Build.Result
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
    destination = Path.join([namespace, "web", metadata.generation])

    with {:ok, manifest} <- read_manifest(source),
         :ok <- Manifest.validate(source, manifest),
         true <- manifest["generation"] == metadata.generation,
         {:ok, published?} <- publish_generation(source, destination, manifest) do
      finish_publication(
        namespace,
        destination,
        manifest,
        result,
        published?
      )
    else
      false ->
        error(:invalid_manifest, "Web release generation does not match its manifest")

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp finish_publication(namespace, destination, manifest, result, published?) do
    previous = selected_generation(Path.join(namespace, "web-current.json"))

    with :ok <- select(namespace, manifest),
         :ok <- cleanup(namespace, manifest["generation"], previous) do
      {:ok,
       %{
         result
         | artifact: Path.join(destination, manifest["entry"]),
           metadata: %{result.metadata | manifest: Path.join(destination, "manifest.json")}
       }}
    else
      {:error, %Error{} = error} ->
        if published?, do: remove(destination)
        {:error, error}
    end
  end

  defp publish_generation(source, destination, manifest) do
    case File.lstat(destination) do
      {:ok, %{type: :directory}} ->
        with :ok <- Manifest.validate(destination, manifest) do
          {:ok, false}
        end

      {:ok, _stat} ->
        error(:publish, "Web release generation path is not a directory: #{destination}")

      {:error, :enoent} ->
        temporary =
          Path.join(
            Path.dirname(destination),
            ".tmp-#{System.unique_integer([:positive, :monotonic])}"
          )

        with :ok <- mkdir(Path.dirname(destination)),
             :ok <- copy_directory(source, temporary),
             :ok <- Manifest.validate(temporary, manifest),
             :ok <- File.rename(temporary, destination) do
          {:ok, true}
        else
          {:error, %Error{} = error} ->
            File.rm_rf(temporary)
            {:error, error}

          {:error, reason} ->
            File.rm_rf(temporary)
            file_error(:publish, destination, reason)
        end

      {:error, reason} ->
        file_error(:publish, destination, reason)
    end
  end

  defp copy_directory(source, destination) do
    with :ok <- mkdir(destination),
         {:ok, names} <- File.ls(source) do
      Enum.reduce_while(Enum.sort(names), :ok, fn name, :ok ->
        from = Path.join(source, name)
        to = Path.join(destination, name)

        case File.lstat(from) do
          {:ok, %{type: :directory}} ->
            case copy_directory(from, to) do
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

  defp select(namespace, manifest) do
    destination = Path.join(namespace, "web-current.json")
    temporary = destination <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    selector =
      Jason.encode!(%{
        "generation" => manifest["generation"],
        "entry" => Path.join(["web", manifest["generation"], manifest["entry"]]),
        "manifest" => Path.join(["web", manifest["generation"], "manifest.json"])
      })

    with :ok <- mkdir(namespace),
         :ok <- File.write(temporary, selector),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        file_error(:selector_write, destination, reason)
    end
  end

  defp cleanup(namespace, selected, previous) do
    root = Path.join(namespace, "web")

    retained =
      root
      |> generation_directories()
      |> Enum.sort_by(fn {_path, modified} -> modified end, :desc)
      |> keep(selected, previous)

    root
    |> generation_directories()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&MapSet.member?(retained, &1))
    |> Enum.each(&remove/1)

    remove_temporaries(root)
    :ok
  end

  defp generation_directories(root) do
    case File.ls(root) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(root, name)

          with true <- Regex.match?(@generation, name),
               {:ok, %{type: :directory, mtime: modified}} <- File.stat(path, time: :posix),
               {:ok, %{type: :directory}} <- File.lstat(path) do
            [{path, modified}]
          else
            _error -> []
          end
        end)

      _error ->
        []
    end
  end

  defp keep(generations, selected, previous) do
    preferred =
      [selected, previous]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn name ->
        Enum.filter(generations, &(Path.basename(elem(&1, 0)) == name))
      end)

    (preferred ++ Enum.reject(generations, &(&1 in preferred)))
    |> Enum.take(@retained)
    |> MapSet.new(&elem(&1, 0))
  end

  defp remove_temporaries(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, ".tmp-"))
        |> Enum.each(fn name -> remove(Path.join(root, name)) end)

      _error ->
        :ok
    end
  end

  defp selected_generation(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"generation" => generation}} <- Jason.decode(contents),
         true <- is_binary(generation),
         true <- Regex.match?(@generation, generation) do
      generation
    else
      _error -> nil
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

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> file_error(:mkdir, path, reason)
    end
  end

  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, file} -> Logger.warning("could not remove #{file}: #{inspect(reason)}")
    end
  end

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
