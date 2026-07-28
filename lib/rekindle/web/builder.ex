defmodule Rekindle.Web.Builder do
  @moduledoc false

  alias Rekindle.Build.Result
  alias Rekindle.Publication
  alias Rekindle.Toolchain.Process
  alias Rekindle.Web.Error

  @entry "app.js"

  @spec build(Rekindle.Config.t(), Rekindle.Config.Target.t(), :dev | :release, keyword()) ::
          {:ok, Result.t()}
          | {:error, Rekindle.Cargo.Error.t() | Rekindle.Toolchain.Error.t() | Error.t()}
  def build(project, target, profile, options) do
    with {:ok, temporary} <- temporary_directory(project, profile) do
      try do
        build(project, target, profile, options, temporary)
      after
        File.rm_rf(temporary)
      end
    end
  end

  defp build(project, target, profile, options, temporary) do
    generation = generation()

    with {:ok, cargo} <-
           Rekindle.Cargo.build(project, target, profile, cargo_options(options)),
         {:ok, wasm_bindgen} <-
           Rekindle.Toolchain.resolve_wasm_bindgen(
             Rekindle.Toolchain.wasm_bindgen_version(),
             toolchain_options(options)
           ),
         :ok <- bindgen(wasm_bindgen, cargo.artifact, temporary, options),
         :ok <- copy_public(project.client_root, temporary),
         :ok <- ensure_entry(temporary),
         {:ok, generation_root} <- publish(project, profile, temporary, generation) do
      result = %Result{
        target: :web,
        profile: profile,
        artifact: Path.join(generation_root, @entry),
        metadata: %{
          generation: generation,
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
  def activate(
        project,
        %Result{target: :web, profile: :dev, artifact: artifact, metadata: metadata}
      ) do
    root = Path.join([state_root(project, :dev), "web", metadata.generation])
    expected = Path.join(root, @entry)
    previous = selected_generation(project)

    with true <- artifact == expected and File.regular?(expected),
         :ok <- select_development(project, metadata.generation) do
      Rekindle.Development.Cleanup.web(project, metadata.generation, previous)
      :ok
    else
      false -> error(:missing_entry, "Web generation entry is missing")
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

      {:error, {:invalid_option, option}} ->
        error(:invalid_option, "invalid wasm-bindgen process option: #{option}")
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

  defp ensure_entry(root) do
    if File.regular?(Path.join(root, @entry)) do
      :ok
    else
      error(:missing_entry, "wasm-bindgen did not produce #{@entry}")
    end
  end

  defp publish(project, profile, temporary, generation) do
    parent = generation_parent(project, profile)
    destination = Path.join(parent, generation)

    with :ok <- File.mkdir_p(parent),
         :ok <- File.rename(temporary, destination) do
      {:ok, destination}
    else
      {:error, reason} -> file_error(:publish, destination, reason)
    end
  end

  defp select_development(project, generation) do
    root = state_root(project, :dev)
    destination = Path.join(root, "web-current.json")
    selector = Jason.encode!(%{"generation" => generation})

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

  defp select_release(project, generation) do
    namespace = Path.join(project.public_dir, "rekindle")
    destination = Path.join(namespace, "entry.js")
    module = Jason.encode!("./web/#{generation}/#{@entry}")

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

  defp finish(project, %Result{profile: :release, metadata: metadata} = result, _options) do
    case select_release(project, metadata.generation) do
      :ok -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error}
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

  defp temporary_directory(project, profile) do
    parent =
      case profile do
        :dev -> Path.join([project.root, ".rekindle", "tmp", "web"])
        :release -> generation_parent(project, :release)
      end

    with :ok <- File.mkdir_p(parent) do
      case Publication.temporary_directory(parent, ".tmp-web-") do
        {:ok, path} -> {:ok, path}
        {:error, reason} -> file_error(:mkdir, parent, reason)
      end
    else
      {:error, reason} -> file_error(:mkdir, parent, reason)
    end
  end

  defp state_root(project, :dev), do: Path.join([project.root, ".rekindle", "dev"])

  defp generation_parent(project, :dev),
    do: Path.join([state_root(project, :dev), "web"])

  defp generation_parent(project, :release),
    do: Path.join([project.public_dir, "rekindle", "web"])

  defp selected_generation(project) do
    path = Path.join(state_root(project, :dev), "web-current.json")

    with {:ok, contents} <- File.read(path),
         {:ok, %{"generation" => generation}} <- Jason.decode(contents),
         true <- is_binary(generation) do
      generation
    else
      _error -> nil
    end
  end

  defp generation do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
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

  defp toolchain_options(options), do: Keyword.take(options, [:timeout, :env])

  defp file_error(kind, path, reason),
    do: error(kind, "cannot update #{path}: #{:file.format_error(reason)}")

  defp error(kind, message, options \\ []),
    do: {:error, Error.new(kind, message, options)}
end
