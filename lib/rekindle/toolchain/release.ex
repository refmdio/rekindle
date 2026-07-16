defmodule Rekindle.Toolchain.Release do
  @moduledoc false

  alias Rekindle.Toolchain.{CompatibilityManifest, Executable, Installer, Rustup}

  @rust_toolchain "1.95.0"

  @spec ensure(boolean(), keyword()) :: {:ok, Path.t()} | {:error, Rekindle.Failure.t()}
  def ensure(source_build?, options \\ []) when is_boolean(source_build?) do
    if source_build? do
      install_source_build(options)
    else
      install_release_asset(options)
    end
  end

  defp install_release_asset(options) do
    with {:ok, release} <- CompatibilityManifest.load(options),
         {:ok, asset} <- CompatibilityManifest.host_asset(release) do
      Installer.ensure(asset,
        cache_root: Keyword.get_lazy(options, :cache_root, &cache_root/0),
        rekindle_version: release.rekindle_version,
        offline: Keyword.get(options, :offline, false),
        fetcher: Keyword.get(options, :fetcher, &fetch!/3)
      )
    end
  end

  defp install_source_build(options) do
    offline? = Keyword.get(options, :offline, false)

    with :ok <- reject_source_override(options),
         {:ok, release} <- CompatibilityManifest.load(options),
         {:ok, asset} <- CompatibilityManifest.host_asset(release) do
      Installer.ensure(asset,
        cache_root: Keyword.get_lazy(options, :cache_root, &cache_root/0),
        rekindle_version: release.rekindle_version,
        source_build: true,
        offline: offline?,
        source_builder: fn ^asset -> source_bytes!(offline?) end
      )
    end
  rescue
    error ->
      {:error,
       Rekindle.Failure.new!(
         target: nil,
         stage: :compatibility,
         code: :helper_missing,
         message: Exception.message(error)
       )}
  end

  defp reject_source_override(options) do
    if Keyword.has_key?(options, :source_root) or Keyword.has_key?(options, :source_builder) do
      {:error,
       Rekindle.Failure.new!(
         target: nil,
         stage: :compatibility,
         code: :helper_missing,
         message: "helper source and builder are package-owned and cannot be overridden"
       )}
    else
      :ok
    end
  end

  defp source_bytes!(offline?) do
    root = packaged_source_root!()
    build_source!(root, offline?)
  end

  defp build_source!(root, offline?) do
    manifest = Path.join(root, "Cargo.toml")
    rustup = Rustup.resolve!()

    arguments =
      ["run", @rust_toolchain, "cargo", "build", "--release", "--locked"] ++
        if(offline?, do: ["--offline"], else: []) ++ ["--manifest-path", manifest]

    case Executable.run(rustup, arguments) do
      {:ok, {_output, 0}} ->
        File.read!(Path.join(root, "target/release/rekindle_toolchain"))

      {:ok, {output, status}} ->
        raise "rekindle_toolchain source build failed (#{status}): #{output}"

      {:error, reason} ->
        raise "rekindle_toolchain source build failed: #{reason}"
    end
  end

  defp packaged_source_root! do
    root =
      if current_project?() do
        Mix.Project.project_file() |> Path.dirname()
      else
        dependency_root!()
      end

    source = Path.join(root, "crates/rekindle-toolchain")
    qualify_source!(source)
    source
  end

  defp current_project? do
    Code.ensure_loaded?(Mix.Project) and not is_nil(Mix.Project.get()) and
      Mix.Project.config()[:app] == :rekindle
  end

  defp dependency_root! do
    if Code.ensure_loaded?(Mix.Project) and not is_nil(Mix.Project.get()) do
      Mix.Project.deps_paths()[:rekindle] ||
        raise "packaged rekindle-toolchain source is unavailable"
    else
      raise "packaged rekindle-toolchain source requires Mix project context"
    end
  end

  defp qualify_source!(root) do
    required = ~w[Cargo.toml Cargo.lock rust-toolchain.toml]

    with {:ok, %{type: :directory}} <- Executable.stat(root),
         {:ok, %{type: :directory}} <- Executable.stat(Path.join(root, "src")),
         true <- Enum.all?(required, &qualified_source_file?(Path.join(root, &1))),
         [_ | _] = source_files <- source_files!(Path.join(root, "src")),
         true <- Enum.all?(source_files, &qualified_source_file?/1),
         true <- pinned_toolchain?(Path.join(root, "rust-toolchain.toml")) do
      :ok
    else
      _ -> raise "packaged rekindle-toolchain source is unavailable or unqualified"
    end
  end

  defp source_files!(directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn entry ->
      path = Path.join(directory, entry)

      case Executable.stat(path) do
        {:ok, %{type: :regular}} -> [path]
        {:ok, %{type: :directory}} -> source_files!(path)
        _ -> raise "packaged helper source contains an unqualified node"
      end
    end)
  end

  defp qualified_source_file?(path) do
    match?({:ok, _authority}, Executable.qualify(path, executable: false))
  end

  defp pinned_toolchain?(path) do
    path
    |> File.read!()
    |> then(&Regex.run(~r/^channel = "([^"]+)"$/m, &1, capture: :all_but_first))
    |> Kernel.==([@rust_toolchain])
  end

  defp fetch!(url, io, maximum) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [],
           sync: false,
           stream: :self
         ) do
      {:ok, request} -> stream_response(request, io, maximum, 0)
      {:error, reason} -> raise "helper download failed: #{inspect(reason)}"
    end
  end

  defp stream_response(request, io, maximum, received) do
    receive do
      {:http, {^request, :stream_start, headers}} ->
        if Enum.any?(headers, fn {name, _value} ->
             name |> List.to_string() |> String.downcase() == "content-range"
           end) do
          :httpc.cancel_request(request)
          raise "partial helper responses are not accepted"
        end

        case Enum.find(headers, fn {name, _value} ->
               name |> List.to_string() |> String.downcase() == "content-length"
             end) do
          {_name, value} ->
            if value |> List.to_string() |> String.to_integer() > maximum do
              :httpc.cancel_request(request)
              raise "helper download exceeded its declared size"
            end

          nil ->
            :ok
        end

        stream_response(request, io, maximum, received)

      {:http, {^request, :stream, chunk}} ->
        next = received + IO.iodata_length(chunk)

        if next > maximum do
          :httpc.cancel_request(request)
          raise "helper download exceeded its declared size"
        end

        IO.binwrite(io, chunk)
        stream_response(request, io, maximum, next)

      {:http, {^request, :stream_end, _headers}} ->
        :ok

      {:http, {^request, {{_version, status, _reason}, _headers, _body}}} ->
        raise "helper download failed (#{status})"

      {:http, {^request, {:error, reason}}} ->
        raise "helper download failed: #{inspect(reason)}"
    after
      30_000 ->
        :httpc.cancel_request(request)
        raise "helper download timed out"
    end
  end

  defp cache_root do
    case System.get_env("XDG_CACHE_HOME") do
      nil -> Path.join(System.user_home!(), ".cache/rekindle/helpers")
      root -> Path.join(root, "rekindle/helpers")
    end
  end
end
