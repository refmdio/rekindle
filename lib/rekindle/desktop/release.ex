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
         true <- manifest["integration"] == Atom.to_string(project.integration),
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
    with :ok <- File.mkdir_p(destination),
         {:ok, temporary} <- Publication.temporary_directory(destination, ".tmp-release-") do
      try do
        executable = manifest["executable"]

        with :ok <-
               copy_executable(
                 Path.join(source, executable),
                 Path.join(temporary, executable)
               ),
             :ok <- File.write(Path.join(temporary, "manifest.json"), Jason.encode!(manifest)),
             :ok <- Manifest.validate(temporary, manifest),
             :ok <-
               File.rename(
                 Path.join(temporary, executable),
                 Path.join(destination, executable)
               ),
             :ok <-
               File.rename(
                 Path.join(temporary, "manifest.json"),
                 Path.join(destination, "manifest.json")
               ) do
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
