defmodule Rekindle.Desktop.Builder do
  @moduledoc false

  alias Rekindle.Build.Result
  alias Rekindle.Desktop.{Error, Manifest}
  alias Rekindle.Publication

  @executable "application"

  @spec build(Rekindle.Config.t(), Rekindle.Config.Target.t(), :dev | :release, keyword()) ::
          {:ok, Result.t()} | {:error, Rekindle.Cargo.Error.t() | Error.t()}
  def build(project, target, profile, options) do
    with {:ok, temporary} <- temporary_directory(project) do
      try do
        build(project, target, profile, options, temporary)
      after
        File.rm_rf(temporary)
      end
    end
  end

  defp build(project, target, profile, options, temporary) do
    with {:ok, cargo} <-
           Rekindle.Cargo.build(project, target, profile, cargo_options(options)),
         :ok <- copy_executable(cargo.artifact, Path.join(temporary, @executable)),
         {:ok, manifest} <-
           Manifest.create(
             temporary,
             @executable,
             cargo.target,
             cargo.package,
             cargo.binary,
             project.integration
           ),
         :ok <- File.write(Path.join(temporary, "manifest.json"), Jason.encode!(manifest)),
         {:ok, output} <- output(project, profile, temporary, manifest) do
      result = %Result{
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
      }

      if profile == :release,
        do: Rekindle.Desktop.Release.publish(project, result),
        else: {:ok, result}
    else
      {:error, reason} when is_atom(reason) ->
        file_error(:manifest_write, Path.join(temporary, "manifest.json"), reason)

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

  defp output(_project, :release, temporary, _manifest), do: {:ok, temporary}

  defp output(project, :dev, temporary, manifest) do
    parent = Path.join([project.root, ".rekindle", "dev", "desktop", manifest["target"]])
    destination = Path.join(parent, build_id())

    with :ok <- File.mkdir_p(parent),
         :ok <- File.rename(temporary, destination),
         :ok <- Manifest.validate(destination, manifest) do
      {:ok, destination}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> file_error(:publish, destination, reason)
    end
  end

  defp temporary_directory(project) do
    parent = Path.join([project.root, ".rekindle", "tmp", "desktop"])

    with :ok <- File.mkdir_p(parent) do
      case Publication.temporary_directory(parent, "build-") do
        {:ok, path} -> {:ok, path}
        {:error, reason} -> file_error(:mkdir, parent, reason)
      end
    else
      {:error, reason} -> file_error(:mkdir, parent, reason)
    end
  end

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
