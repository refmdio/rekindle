defmodule Rekindle.Toolchain.Release do
  @moduledoc false

  alias Rekindle.Toolchain.{CompatibilityManifest, Helper, Installer, Rustup}

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
        fetcher: Keyword.get(options, :fetcher, &fetch!/1)
      )
    end
  end

  defp install_source_build(options) do
    bytes = invoke_source_builder(options)
    host = Installer.host()

    asset = %{
      "os" => host.os,
      "arch" => host.arch,
      "url" => nil,
      "size" => byte_size(bytes),
      "sha256" => sha256(bytes)
    }

    Installer.ensure(asset,
      cache_root: Keyword.get_lazy(options, :cache_root, &cache_root/0),
      rekindle_version: Helper.compatibility()["helper_version"],
      source_build: true,
      offline: Keyword.get(options, :offline, false),
      source_builder: fn ^asset -> bytes end
    )
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

  defp invoke_source_builder(options) do
    case Keyword.get(options, :source_builder) do
      function when is_function(function, 0) -> function.()
      nil -> build_source!(Keyword.get(options, :source_root))
    end
  end

  defp build_source!(override) do
    root = override || source_root!()
    manifest = Path.join(root, "Cargo.toml")
    rustup = Rustup.resolve!()

    case System.cmd(
           rustup,
           [
             "run",
             @rust_toolchain,
             "cargo",
             "build",
             "--release",
             "--locked",
             "--manifest-path",
             manifest
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        File.read!(Path.join(root, "target/release/rekindle_toolchain"))

      {output, status} ->
        raise "rekindle_toolchain source build failed (#{status}): #{output}"
    end
  end

  defp source_root! do
    candidates =
      [Path.expand("crates/rekindle-toolchain"), dependency_source_root()]
      |> Enum.reject(&is_nil/1)

    Enum.find(candidates, &File.regular?(Path.join(&1, "Cargo.toml"))) ||
      raise "packaged rekindle-toolchain source is unavailable"
  end

  defp dependency_source_root do
    if Code.ensure_loaded?(Mix.Project) do
      case Mix.Project.deps_paths()[:rekindle] do
        nil -> nil
        path -> Path.join(path, "crates/rekindle-toolchain")
      end
    end
  end

  defp fetch!(url) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        body

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        raise "helper download failed (#{status})"

      {:error, reason} ->
        raise "helper download failed: #{inspect(reason)}"
    end
  end

  defp cache_root do
    case System.get_env("XDG_CACHE_HOME") do
      nil -> Path.join(System.user_home!(), ".cache/rekindle/helpers")
      root -> Path.join(root, "rekindle/helpers")
    end
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
