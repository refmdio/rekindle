defmodule Rekindle.Web.Builder do
  @moduledoc false

  alias Rekindle.Build.Result
  alias Rekindle.Toolchain.Process
  alias Rekindle.Web.{Error, Manifest}

  @entry "app.js"

  @spec build(Rekindle.Config.t(), Rekindle.Config.Target.t(), :dev | :release, keyword()) ::
          {:ok, Result.t()}
          | {:error, Rekindle.Cargo.Error.t() | Rekindle.Toolchain.Error.t() | Error.t()}
  def build(project, target, profile, options) do
    temporary = temporary_path(project)

    try do
      with :ok <- mkdir(temporary),
           {:ok, cargo} <- Rekindle.Cargo.build(project, target, profile, cargo_options(options)),
           {:ok, wasm_bindgen} <-
             Rekindle.Toolchain.resolve_wasm_bindgen(
               Rekindle.Toolchain.wasm_bindgen_version(),
               toolchain_options(options)
             ),
           :ok <- bindgen(wasm_bindgen, cargo.artifact, temporary, options),
           :ok <- copy_public(project.client_root, temporary),
           {:ok, manifest} <- Manifest.create(temporary, @entry),
           :ok <- write_manifest(temporary, manifest),
           {:ok, generation} <- publish(project, profile, temporary, manifest),
           {:ok, result} <-
             finish(
               project,
               %Result{
                 target: :web,
                 profile: profile,
                 artifact: Path.join(generation, @entry),
                 metadata: %{
                   generation: manifest["generation"],
                   manifest: Path.join(generation, "manifest.json"),
                   package: cargo.package,
                   binary: cargo.binary,
                   rust_target: cargo.target,
                   target_directory: cargo.target_directory,
                   diagnostics: cargo.diagnostics
                 }
               },
               manifest,
               options
             ) do
        {:ok, result}
      end
    after
      File.rm_rf(temporary)
    end
  end

  @doc false
  @spec activate(Rekindle.Config.t(), Result.t()) :: :ok | {:error, Error.t()}
  def activate(project, %Result{target: :web, profile: profile, metadata: metadata}) do
    with :ok <- select(project, profile, %{"generation" => metadata.generation}) do
      if profile == :dev, do: Rekindle.Development.Cleanup.web(project, metadata.generation)
      :ok
    end
  end

  defp bindgen(executable, artifact, output, options) do
    arguments = [
      artifact,
      "--target",
      "web",
      "--out-dir",
      output,
      "--out-name",
      "app"
    ]

    case Process.run(executable, arguments,
           cd: Path.dirname(artifact),
           timeout: Keyword.get(options, :timeout, 120_000),
           output_limit: Keyword.get(options, :output_limit, 8_000_000),
           cancel_ref: Keyword.get(options, :cancel_ref),
           env: Keyword.get(options, :process_env, [])
         ) do
      {:ok, %{status: 0, truncated?: false}} ->
        :ok

      {:ok, %{truncated?: true}} ->
        error(:output_limit, "wasm-bindgen output exceeded the limit")

      {:ok, result} ->
        error(:wasm_bindgen, "wasm-bindgen failed with status #{result.status}",
          output: result.output
        )

      {:error, :timeout} ->
        error(:timeout, "wasm-bindgen timed out")

      {:error, :cancelled} ->
        error(:cancelled, "wasm-bindgen was cancelled")

      {:error, {:start, reason}} ->
        error(:start_failed, "wasm-bindgen could not start: #{Exception.message(reason)}")
    end
  end

  defp copy_public(client_root, generation) do
    public = Path.join(client_root, "public")

    case File.lstat(public) do
      {:ok, %{type: :directory}} -> copy_directory(public, generation)
      {:ok, _stat} -> error(:copy_public, "client/public is not a directory")
      {:error, :enoent} -> :ok
      {:error, reason} -> file_error(:copy_public, public, reason)
    end
  end

  defp copy_directory(source, destination) do
    case File.ls(source) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), :ok, fn name, :ok ->
          source_path = Path.join(source, name)
          destination_path = Path.join(destination, name)

          case File.lstat(source_path) do
            {:ok, %{type: :directory}} ->
              with :ok <- ensure_absent(destination_path),
                   :ok <- File.mkdir(destination_path),
                   :ok <- copy_directory(source_path, destination_path) do
                {:cont, :ok}
              else
                {:error, %Error{} = error} -> {:halt, {:error, error}}
                {:error, reason} -> {:halt, file_error(:copy_public, destination_path, reason)}
              end

            {:ok, %{type: :regular}} ->
              with :ok <- ensure_absent(destination_path),
                   :ok <- File.cp(source_path, destination_path) do
                {:cont, :ok}
              else
                {:error, %Error{} = error} -> {:halt, {:error, error}}
                {:error, reason} -> {:halt, file_error(:copy_public, destination_path, reason)}
              end

            {:ok, _stat} ->
              {:halt, error(:copy_public, "public asset is not a regular file: #{source_path}")}

            {:error, reason} ->
              {:halt, file_error(:copy_public, source_path, reason)}
          end
        end)

      {:error, reason} ->
        file_error(:copy_public, source, reason)
    end
  end

  defp ensure_absent(path) do
    case File.lstat(path) do
      {:ok, _stat} ->
        error(
          :asset_collision,
          "public asset collides with generated member: #{Path.basename(path)}"
        )

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        file_error(:copy_public, path, reason)
    end
  end

  defp write_manifest(root, manifest) do
    path = Path.join(root, "manifest.json")

    with :ok <- ensure_absent(path),
         :ok <- File.write(path, Jason.encode!(manifest)),
         :ok <- Manifest.validate(root, manifest) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> file_error(:manifest_write, path, reason)
    end
  end

  defp publish(project, profile, temporary, manifest) do
    parent = generation_parent(project, profile)
    destination = Path.join(parent, manifest["generation"])

    with :ok <- mkdir(parent),
         {:ok, destination} <-
           rename_generation(temporary, destination, manifest["generation"]),
         :ok <- validate_published(destination, manifest["generation"]) do
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
        error(:invalid_manifest, "published Web generation does not match its directory")

      {:error, %Jason.DecodeError{} = error} ->
        error(:invalid_manifest, "published Web manifest is invalid: #{Exception.message(error)}")

      {:error, reason} when is_atom(reason) ->
        file_error(:manifest_read, path, reason)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp select(project, profile, manifest) do
    root = state_root(project, profile)
    destination = Path.join(root, "web-current.json")
    temporary = destination <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    selector =
      Jason.encode!(%{
        "generation" => manifest["generation"],
        "manifest" => Path.join(["web", manifest["generation"], "manifest.json"])
      })

    with :ok <- mkdir(root),
         :ok <- File.write(temporary, selector),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        file_error(:selector_write, destination, reason)
    end
  end

  defp finish(project, %Result{profile: :release} = result, _manifest, _options),
    do: Rekindle.Web.Release.publish(project, result)

  defp finish(project, result, manifest, options) do
    if Keyword.get(options, :activate, true) do
      case select(project, result.profile, manifest) do
        :ok -> {:ok, result}
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      {:ok, result}
    end
  end

  defp temporary_path(project) do
    Path.join([
      project.root,
      ".rekindle",
      "tmp",
      "web",
      Integer.to_string(System.unique_integer([:positive, :monotonic]))
    ])
  end

  defp generation_parent(project, profile), do: Path.join([state_root(project, profile), "web"])

  defp state_root(project, :dev), do: Path.join([project.root, ".rekindle", "dev"])
  defp state_root(project, :release), do: Path.join([project.root, ".rekindle", "release"])

  defp cargo_options(options),
    do: Keyword.take(options, [:cargo, :rustc, :timeout, :output_limit, :cancel_ref, :env])

  defp toolchain_options(options),
    do: Keyword.take(options, [:timeout, :env])

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> file_error(:mkdir, path, reason)
    end
  end

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{:file.format_error(reason)}")

  defp error(kind, message, options \\ []),
    do: {:error, Error.new(kind, message, options)}
end
