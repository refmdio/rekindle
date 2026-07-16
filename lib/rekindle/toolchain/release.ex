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
        fetcher: Keyword.get(options, :fetcher, &fetch!/3)
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

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
