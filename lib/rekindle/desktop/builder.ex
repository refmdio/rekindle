defmodule Rekindle.Desktop.Builder do
  @moduledoc false

  alias Rekindle.Build.Result
  alias Rekindle.Desktop.{Error, Manifest}

  @spec build(Rekindle.Config.t(), Rekindle.Config.Target.t(), :dev | :release, keyword()) ::
          {:ok, Result.t()} | {:error, Rekindle.Cargo.Error.t() | Error.t()}
  def build(project, target, profile, options) do
    temporary = temporary_path(project)

    try do
      with {:ok, cargo} <-
             Rekindle.Cargo.build(project, target, profile, cargo_options(options)),
           :ok <- mkdir(temporary),
           executable <- Path.basename(cargo.artifact),
           :ok <- copy_executable(cargo.artifact, Path.join(temporary, executable)),
           {:ok, manifest} <-
             Manifest.create(
               temporary,
               executable,
               cargo.target,
               cargo.package,
               cargo.binary
             ),
           :ok <- write_manifest(temporary, manifest),
           {:ok, generation} <- publish(project, profile, temporary, manifest) do
        {:ok,
         %Result{
           target: :desktop,
           profile: profile,
           artifact: Path.join(generation, executable),
           metadata: %{
             generation: manifest["generation"],
             manifest: Path.join(generation, "manifest.json"),
             package: cargo.package,
             binary: cargo.binary,
             rust_target: cargo.target,
             target_directory: cargo.target_directory,
             diagnostics: cargo.diagnostics
           }
         }}
      end
    after
      File.rm_rf(temporary)
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
        error(:not_executable, "Cargo artifact is not executable: #{source}")

      {:ok, _stat} ->
        error(:invalid_executable, "Cargo artifact is not a regular file: #{source}")

      {:error, reason} ->
        file_error(:copy, destination, reason)
    end
  end

  defp write_manifest(root, manifest) do
    path = Path.join(root, "manifest.json")

    case File.write(path, Jason.encode!(manifest)) do
      :ok -> Manifest.validate(root, manifest)
      {:error, reason} -> file_error(:manifest_write, path, reason)
    end
  end

  defp publish(project, profile, temporary, manifest) do
    parent =
      Path.join([
        state_root(project, profile),
        "desktop",
        manifest["target"]
      ])

    destination = Path.join(parent, manifest["generation"])

    with :ok <- mkdir(parent),
         {:ok, destination} <-
           rename_generation(temporary, destination, manifest["generation"]) do
      {:ok, destination}
    end
  end

  defp rename_generation(temporary, destination, generation) do
    case File.rename(temporary, destination) do
      :ok ->
        {:ok, destination}

      {:error, reason} when reason in [:eexist, :enotempty] ->
        case validate_published(destination, generation) do
          :ok -> {:ok, destination}
          {:error, %Error{} = error} -> {:error, error}
        end

      {:error, reason} ->
        file_error(:publish, destination, reason)
    end
  end

  defp validate_published(root, expected_generation) do
    path = Path.join(root, "manifest.json")

    with {:ok, contents} <- File.read(path),
         {:ok, manifest} <- Jason.decode(contents),
         true <- manifest["generation"] == expected_generation,
         :ok <- Manifest.validate(root, manifest) do
      :ok
    else
      false ->
        error(:invalid_manifest, "desktop generation does not match its directory")

      {:error, %Jason.DecodeError{} = error} ->
        error(:invalid_manifest, "desktop manifest is invalid: #{Exception.message(error)}")

      {:error, reason} when is_atom(reason) ->
        file_error(:manifest_read, path, reason)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp temporary_path(project) do
    Path.join([
      project.root,
      ".rekindle",
      "tmp",
      "desktop",
      Integer.to_string(System.unique_integer([:positive, :monotonic]))
    ])
  end

  defp state_root(project, :dev), do: Path.join([project.root, ".rekindle", "dev"])
  defp state_root(project, :release), do: Path.join([project.root, ".rekindle", "release"])

  defp cargo_options(options) do
    Keyword.take(options, [
      :cargo,
      :rustc,
      :timeout,
      :output_limit,
      :cancel_ref,
      :env
    ])
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> file_error(:mkdir, path, reason)
    end
  end

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
