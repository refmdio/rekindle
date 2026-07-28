defmodule Rekindle.Desktop.Release do
  @moduledoc false

  alias Rekindle.Build.Result
  alias Rekindle.Desktop.{Error, Manifest}
  alias Rekindle.Publication

  @spec publish(Rekindle.Config.t(), Result.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def publish(
        project,
        %Result{target: :desktop, profile: :release, metadata: metadata} = result
      ) do
    source = Path.dirname(metadata.manifest)
    destination = Path.join([project.root, "dist", "rekindle", "desktop", metadata.rust_target])

    with {:ok, manifest} <- Manifest.read(source),
         true <- manifest["target"] == metadata.rust_target,
         true <- manifest["plugin"] == Rekindle.Plugin.name(project.plugin),
         :ok <- Manifest.validate(source, manifest),
         :ok <- publish_files(source, destination, manifest) do
      {:ok,
       %{
         result
         | artifact: Path.join(destination, manifest["executable"]),
           metadata: %{metadata | manifest: Path.join(destination, "manifest.json")}
       }}
    else
      false -> error(:invalid_manifest, "desktop release does not match its build manifest")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp publish_files(source, destination, manifest) do
    parent = Path.dirname(destination)

    with :ok <- File.mkdir_p(parent),
         {:ok, temporary} <- Publication.temporary_directory(parent, ".tmp-release-") do
      try do
        executable = manifest["executable"]

        with :ok <- copy_existing(destination, temporary),
             :ok <-
               copy_executable(
                 Path.join(source, executable),
                 Path.join(temporary, executable)
               ),
             :ok <- File.write(Path.join(temporary, "manifest.json"), Jason.encode!(manifest)),
             :ok <- Manifest.validate(temporary, manifest),
             :ok <- replace_directory(temporary, destination) do
          :ok
        else
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

  defp copy_existing(source, destination) do
    case File.stat(source) do
      {:ok, %{type: :directory}} ->
        case File.cp_r(source, destination) do
          {:ok, _paths} -> :ok
          {:error, reason, path} -> file_error(:copy, path, reason)
        end

      {:ok, _stat} ->
        error(:invalid_destination, "desktop release destination is not a directory: #{source}")

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        file_error(:copy, source, reason)
    end
  end

  defp replace_directory(source, destination) do
    case File.stat(destination) do
      {:ok, %{type: :directory}} -> replace_existing_directory(source, destination)
      {:ok, _stat} -> {:error, :enotdir}
      {:error, :enoent} -> File.rename(source, destination)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_existing_directory(source, destination) do
    parent = Path.dirname(destination)

    with {:ok, backup} <- Publication.temporary_directory(parent, ".tmp-backup-"),
         :ok <- File.rmdir(backup),
         :ok <- File.rename(destination, backup) do
      case File.rename(source, destination) do
        :ok ->
          File.rm_rf(backup)
          :ok

        {:error, reason} ->
          rollback_directory(backup, destination, reason)
      end
    end
  end

  defp rollback_directory(backup, destination, publish_reason) do
    case File.rename(backup, destination) do
      :ok ->
        {:error, publish_reason}

      {:error, rollback_reason} ->
        error(
          :publish,
          "cannot replace #{destination}: #{:file.format_error(publish_reason)}; " <>
            "previous release remains at #{backup} because rollback failed: " <>
            :file.format_error(rollback_reason)
        )
    end
  end

  defp copy_executable(source, destination) do
    with {:ok, %{type: :regular, mode: mode}} <- File.stat(source),
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

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
