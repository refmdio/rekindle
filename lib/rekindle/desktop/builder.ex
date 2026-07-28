defmodule Rekindle.Desktop.Builder do
  @moduledoc false

  alias Rekindle.Build.Result
  alias Rekindle.Desktop.{Error, Manifest}
  alias Rekindle.Publication

  @executable "application"

  @spec build(Rekindle.Config.t(), Rekindle.Config.Target.t(), :dev | :release, keyword()) ::
          {:ok, Result.t()} | {:error, Rekindle.Cargo.Error.t() | Error.t()}
  def build(project, target, profile, options) do
    with {:ok, cargo} <-
           Rekindle.Cargo.build(project, target, profile, cargo_options(options)),
         {:ok, temporary} <- temporary_directory(project, profile, cargo.target) do
      try do
        package(project, profile, cargo, temporary)
      after
        File.rm_rf(temporary)
      end
    end
  end

  defp package(project, profile, cargo, temporary) do
    manifest_path = Path.join(temporary, "manifest.json")

    with :ok <- copy_executable(cargo.artifact, Path.join(temporary, @executable)),
         {:ok, manifest} <-
           Manifest.create(
             temporary,
             @executable,
             cargo.target,
             cargo.package,
             cargo.binary,
             Rekindle.Plugin.name(project.plugin)
           ),
         :ok <- File.write(manifest_path, Jason.encode!(manifest)),
         {:ok, output} <- publish(project, profile, cargo.target, temporary) do
      {:ok,
       %Result{
         target: :desktop,
         profile: profile,
         artifact: Path.join(output, @executable),
         metadata: %{
           manifest: Path.join(output, "manifest.json"),
           package: cargo.package,
           binary: cargo.binary,
           rust_target: cargo.target,
           target_directory: cargo.target_directory,
           diagnostics: cargo.diagnostics
         }
       }}
    else
      {:error, reason} when is_atom(reason) ->
        file_error(:manifest_write, manifest_path, reason)

      {:error, error} ->
        {:error, error}
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
        error(:not_executable, "Cargo artifact is not executable: #{source}")

      {:ok, _stat} ->
        error(:invalid_executable, "Cargo artifact is not a regular file: #{source}")

      {:error, reason} ->
        file_error(:copy, destination, reason)
    end
  end

  defp publish(project, :dev, target, temporary) do
    parent = output_parent(project, :dev, target)
    destination = Path.join(parent, build_id())

    with :ok <- File.mkdir_p(parent),
         :ok <- File.rename(temporary, destination) do
      {:ok, destination}
    else
      {:error, reason} -> file_error(:publish, destination, reason)
    end
  end

  defp publish(project, :release, target, temporary) do
    destination = Path.join(output_parent(project, :release, target), target)

    with {:ok, previous} <- move_destination(destination),
         :ok <- replace_destination(temporary, destination, previous) do
      {:ok, destination}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp move_destination(destination) do
    previous = destination <> ".previous-" <> build_id()

    case File.rename(destination, previous) do
      :ok -> {:ok, previous}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> file_error(:publish, destination, reason)
    end
  end

  defp replace_destination(temporary, destination, previous) do
    case File.rename(temporary, destination) do
      :ok ->
        remove_previous(previous)

      {:error, reason} ->
        with :ok <- restore_previous(previous, destination) do
          file_error(:publish, destination, reason)
        end
    end
  end

  defp remove_previous(nil), do: :ok

  defp remove_previous(previous) do
    case File.rm_rf(previous) do
      {:ok, _paths} -> :ok
      {:error, reason, path} -> file_error(:publish, path, reason)
    end
  end

  defp restore_previous(nil, _destination), do: :ok

  defp restore_previous(previous, destination) do
    case File.rename(previous, destination) do
      :ok -> :ok
      {:error, reason} -> file_error(:restore, destination, reason)
    end
  end

  defp temporary_directory(project, profile, target) do
    parent = output_parent(project, profile, target)

    with :ok <- File.mkdir_p(parent) do
      case Publication.temporary_directory(parent, ".tmp-desktop-") do
        {:ok, path} -> {:ok, path}
        {:error, reason} -> file_error(:mkdir, parent, reason)
      end
    else
      {:error, reason} -> file_error(:mkdir, parent, reason)
    end
  end

  defp output_parent(project, :dev, target),
    do: Path.join([project.root, ".rekindle", "dev", "desktop", target])

  defp output_parent(project, :release, _target),
    do: Path.join([project.root, "dist", "rekindle", "desktop"])

  defp cargo_options(options),
    do:
      Keyword.take(options, [
        :cargo,
        :rustc,
        :rustup,
        :timeout,
        :output_limit,
        :env,
        :process_env
      ])

  defp build_id do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
