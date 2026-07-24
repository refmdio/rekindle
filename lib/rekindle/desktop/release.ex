defmodule Rekindle.Desktop.Release do
  @moduledoc false

  require Logger

  alias Rekindle.Build.Result
  alias Rekindle.Desktop.{Error, Manifest}
  alias Rekindle.Publication

  @release_executable ~r/\Aapplication-[0-9a-f]{64}\z/

  @spec publish(Rekindle.Config.t(), Result.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def publish(
        project,
        %Result{target: :desktop, profile: :release, metadata: metadata} = result
      ) do
    source_root = Path.dirname(metadata.manifest)

    destination_root =
      Path.join([project.root, "dist", "rekindle", "desktop", metadata.rust_target])

    with {:ok, source_manifest} <- read_manifest(metadata.manifest),
         :ok <- Manifest.validate(source_root, source_manifest),
         true <- source_manifest["generation"] == metadata.generation,
         true <- source_manifest["target"] == metadata.rust_target,
         true <- source_manifest["integration"] == Atom.to_string(project.integration) do
      with_lock(project, destination_root, fn ->
        publish_locked(destination_root, source_root, source_manifest, result)
      end)
    else
      false ->
        error(:invalid_manifest, "desktop release does not match its build manifest")

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp publish_locked(root, source_root, source_manifest, result) do
    executable = content_name(source_manifest)

    with {:ok, published?} <-
           publish_executable(
             Path.join(source_root, source_manifest["executable"]),
             Path.join(root, executable),
             source_manifest["sha256"]
           ) do
      prepare_publication(
        root,
        executable,
        source_manifest,
        result,
        published?
      )
    end
  end

  defp prepare_publication(root, executable, source_manifest, result, published?) do
    expected_hash = source_manifest["sha256"]

    case Manifest.create(
           root,
           executable,
           source_manifest["target"],
           source_manifest["package"],
           source_manifest["binary"],
           source_manifest["integration"]
         ) do
      {:ok, %{"sha256" => hash} = manifest} when hash == expected_hash ->
        finish_publication(root, manifest, result, published?)

      {:ok, _manifest} ->
        rollback(root, executable, published?)
        error(:executable_hash, "desktop release executable changed during publication")

      {:error, %Error{} = error} ->
        rollback(root, executable, published?)
        {:error, error}
    end
  end

  defp finish_publication(root, manifest, result, published?) do
    case write_manifest(root, manifest) do
      :ok ->
        cleanup(root, manifest["executable"])

        {:ok,
         %{
           result
           | artifact: Path.join(root, manifest["executable"]),
             metadata: %{
               result.metadata
               | generation: manifest["generation"],
                 manifest: Path.join(root, "manifest.json")
             }
         }}

      {:error, %Error{} = error} ->
        if published?, do: remove_regular(Path.join(root, manifest["executable"]))
        {:error, error}
    end
  end

  defp publish_executable(source, destination, expected_hash) do
    case File.lstat(destination) do
      {:ok, %{type: :regular}} ->
        with :ok <- validate_executable(destination, expected_hash) do
          {:ok, false}
        end

      {:ok, _stat} ->
        error(:publish, "desktop release path is not a regular file: #{destination}")

      {:error, :enoent} ->
        with :ok <- mkdir(Path.dirname(destination)),
             {:ok, temporary} <-
               temporary_file(Path.dirname(destination), ".tmp-executable-", :publish) do
          try do
            with :ok <- copy_executable(source, temporary),
                 :ok <- validate_executable(temporary, expected_hash),
                 {:ok, published?} <- link_executable(temporary, destination, expected_hash) do
              {:ok, published?}
            end
          after
            File.rm(temporary)
          end
        end

      {:error, reason} ->
        file_error(:publish, destination, reason)
    end
  end

  defp link_executable(temporary, destination, expected_hash) do
    case File.ln(temporary, destination) do
      :ok ->
        {:ok, true}

      {:error, :eexist} ->
        with :ok <- validate_executable(destination, expected_hash) do
          {:ok, false}
        end

      {:error, reason} ->
        file_error(:publish, destination, reason)
    end
  end

  defp copy_executable(source, destination) do
    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(source),
         true <- Bitwise.band(mode, 0o111) != 0,
         :ok <- File.cp(source, destination),
         :ok <- File.chmod(destination, mode) do
      :ok
    else
      false ->
        error(:not_executable, "desktop release source is not executable: #{source}")

      {:ok, _stat} ->
        error(:invalid_executable, "desktop release source is not a file: #{source}")

      {:error, reason} ->
        file_error(:copy, destination, reason)
    end
  end

  defp validate_executable(path, expected_hash) do
    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o111) != 0,
         {:ok, contents} <- File.read(path),
         true <- sha256(contents) == expected_hash do
      :ok
    else
      false -> error(:executable_hash, "desktop release executable does not match: #{path}")
      {:ok, _stat} -> error(:invalid_executable, "desktop release path is not a file: #{path}")
      {:error, reason} -> file_error(:executable_read, path, reason)
    end
  end

  defp write_manifest(root, manifest) do
    destination = Path.join(root, "manifest.json")

    with {:ok, temporary} <- temporary_file(root, ".tmp-manifest-", :manifest_write) do
      try do
        with :ok <- File.write(temporary, Jason.encode!(manifest)),
             :ok <- Manifest.validate(root, manifest),
             :ok <- File.rename(temporary, destination) do
          :ok
        else
          {:error, %Error{} = error} ->
            {:error, error}

          {:error, reason} ->
            file_error(:manifest_write, destination, reason)
        end
      after
        File.rm(temporary)
      end
    end
  end

  defp cleanup(root, selected) do
    remove_unreferenced(root, selected)
    remove_temporaries(root)
  end

  defp remove_unreferenced(root, selected) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@release_executable, &1))
        |> Enum.reject(&(&1 == selected))
        |> Enum.each(fn name -> remove_regular(Path.join(root, name)) end)

      _error ->
        :ok
    end
  end

  defp remove_temporaries(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, ".tmp-"))
        |> Enum.each(fn name -> remove_regular(Path.join(root, name)) end)

      _error ->
        :ok
    end
  end

  defp rollback(root, executable, true), do: remove_regular(Path.join(root, executable))
  defp rollback(_root, _executable, false), do: :ok

  defp content_name(manifest), do: "application-" <> manifest["sha256"]

  defp read_manifest(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, manifest} <- Jason.decode(contents) do
      {:ok, manifest}
    else
      {:error, %Jason.DecodeError{} = error} ->
        error(
          :invalid_manifest,
          "desktop release manifest is invalid: #{Exception.message(error)}"
        )

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

  defp temporary_file(root, prefix, kind) do
    case Publication.temporary_file(root, prefix) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> file_error(kind, root, reason)
    end
  end

  defp with_lock(project, destination, function) do
    case Publication.with_lock(project.root, {:desktop_release, destination}, function) do
      {:error, {:publication_lock, reason}} ->
        error(:publication_lock, "cannot serialize desktop publication: #{inspect(reason)}")

      result ->
        result
    end
  end

  defp remove_regular(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("could not remove #{path}: #{inspect(reason)}")
        end

      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not inspect #{path}: #{inspect(reason)}")
    end
  end

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
