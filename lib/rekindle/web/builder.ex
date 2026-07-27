defmodule Rekindle.Web.Builder do
  @moduledoc false

  alias Rekindle.Build.Result
  alias Rekindle.Publication
  alias Rekindle.Toolchain.Process
  alias Rekindle.Web.{Error, Manifest}

  @entry "app.js"

  @spec build(Rekindle.Config.t(), Rekindle.Config.Target.t(), :dev | :release, keyword()) ::
          {:ok, Result.t()}
          | {:error, Rekindle.Cargo.Error.t() | Rekindle.Toolchain.Error.t() | Error.t()}
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
         {:ok, wasm_bindgen} <-
           Rekindle.Toolchain.resolve_wasm_bindgen(
             Rekindle.Toolchain.wasm_bindgen_version(),
             toolchain_options(options)
           ),
         :ok <- bindgen(wasm_bindgen, cargo.artifact, temporary, options),
         :ok <- copy_public(project.client_root, temporary),
         {:ok, manifest} <- Manifest.create(temporary, @entry),
         :ok <- write_manifest(temporary, manifest),
         {:ok, generation_root} <- publish(project, profile, temporary, manifest) do
      result = %Result{
        target: :web,
        profile: profile,
        artifact: Path.join(generation_root, @entry),
        metadata: %{
          generation: manifest["generation"],
          manifest: Path.join(generation_root, "manifest.json"),
          package: cargo.package,
          binary: cargo.binary,
          rust_target: cargo.target,
          target_directory: cargo.target_directory,
          diagnostics: cargo.diagnostics
        }
      }

      finish(project, result, options)
    end
  end

  @doc false
  @spec activate(Rekindle.Config.t(), Result.t()) :: :ok | {:error, Error.t()}
  def activate(project, %Result{target: :web, profile: profile, metadata: metadata}) do
    root = Path.join([state_root(project, profile), "web", metadata.generation])
    previous = selected_generation(project, profile)

    with {:ok, manifest} <- Manifest.read(root),
         true <- manifest["generation"] == metadata.generation,
         :ok <- Manifest.validate(root, manifest),
         :ok <- select(project, profile, manifest) do
      if profile == :dev,
        do: Rekindle.Development.Cleanup.web(project, metadata.generation, previous)

      :ok
    else
      false -> error(:invalid_manifest, "Web generation does not match its manifest")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp bindgen(executable, artifact, output, options) do
    arguments = [artifact, "--target", "web", "--out-dir", output, "--out-name", "app"]

    case Process.run(executable, arguments,
           cd: Path.dirname(artifact),
           timeout: Keyword.get(options, :timeout, :infinity),
           output_limit: Keyword.get(options, :output_limit, 8_000_000),
           env: Keyword.get(options, :process_env, [])
         ) do
      {:ok, %{status: 0}} ->
        :ok

      {:error, :output_limit} ->
        error(:output_limit, "wasm-bindgen output exceeded the limit")

      {:ok, result} ->
        error(:wasm_bindgen, "wasm-bindgen failed with status #{result.status}",
          output: result.output
        )

      {:error, :timeout} ->
        error(:timeout, "wasm-bindgen timed out")

      {:error, {:start, reason}} ->
        error(:start_failed, "wasm-bindgen could not start: #{Exception.message(reason)}")
    end
  end

  defp copy_public(client_root, destination) do
    source = Path.join(client_root, "public")

    case File.stat(source) do
      {:ok, %{type: :directory}} -> copy_directory(source, destination)
      {:ok, _stat} -> error(:copy_public, "client/public is not a directory")
      {:error, :enoent} -> :ok
      {:error, reason} -> file_error(:copy_public, source, reason)
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
              {:error, reason} -> {:halt, file_error(:copy_public, to, reason)}
            end

          {:ok, %{type: :regular}} ->
            if File.exists?(to) do
              {:halt,
               error(:asset_collision, "public asset collides with generated output: #{name}")}
            else
              case File.cp(from, to) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, file_error(:copy_public, to, reason)}
              end
            end

          {:ok, _stat} ->
            {:halt, error(:copy_public, "public asset is not a regular file: #{from}")}

          {:error, reason} ->
            {:halt, file_error(:copy_public, from, reason)}
        end
      end)
    else
      {:error, reason} -> file_error(:copy_public, source, reason)
    end
  end

  defp write_manifest(root, manifest) do
    path = Path.join(root, "manifest.json")

    case File.write(path, Jason.encode!(manifest)) do
      :ok -> :ok
      {:error, reason} -> file_error(:manifest_write, path, reason)
    end
  end

  defp publish(project, profile, temporary, manifest) do
    parent = Path.join([state_root(project, profile), "web"])
    destination = Path.join(parent, manifest["generation"])

    with :ok <- File.mkdir_p(parent),
         :ok <- File.rename(temporary, destination) do
      {:ok, destination}
    else
      {:error, reason} -> file_error(:publish, destination, reason)
    end
  end

  defp select(project, profile, manifest) do
    root = state_root(project, profile)
    destination = Path.join(root, "web-current.json")
    selector = Jason.encode!(%{"generation" => manifest["generation"]})

    with :ok <- File.mkdir_p(root),
         {:ok, temporary} <- Publication.temporary_file(root, ".tmp-web-current-") do
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

  defp finish(project, %Result{profile: :release, metadata: metadata} = result, _options) do
    source = Path.dirname(metadata.manifest)

    try do
      Rekindle.Web.Release.publish(project, result)
    after
      File.rm_rf(source)
    end
  end

  defp finish(project, result, options) do
    if Keyword.get(options, :activate, true) do
      case activate(project, result) do
        :ok -> {:ok, result}
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      {:ok, result}
    end
  end

  defp temporary_directory(project) do
    parent = Path.join([project.root, ".rekindle", "tmp", "web"])

    with :ok <- File.mkdir_p(parent) do
      case Publication.temporary_directory(parent, "build-") do
        {:ok, path} -> {:ok, path}
        {:error, reason} -> file_error(:mkdir, parent, reason)
      end
    else
      {:error, reason} -> file_error(:mkdir, parent, reason)
    end
  end

  defp state_root(project, :dev), do: Path.join([project.root, ".rekindle", "dev"])
  defp state_root(project, :release), do: Path.join([project.root, ".rekindle", "release"])

  defp selected_generation(project, profile) do
    path = Path.join(state_root(project, profile), "web-current.json")

    with {:ok, contents} <- File.read(path),
         {:ok, %{"generation" => generation}} <- Jason.decode(contents),
         true <- is_binary(generation) do
      generation
    else
      _error -> nil
    end
  end

  defp cargo_options(options),
    do: Keyword.take(options, [:cargo, :rustc, :timeout, :output_limit, :env])

  defp toolchain_options(options), do: Keyword.take(options, [:timeout, :env])

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{:file.format_error(reason)}")

  defp error(kind, message, options \\ []),
    do: {:error, Error.new(kind, message, options)}
end
