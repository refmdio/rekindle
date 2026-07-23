defmodule Rekindle.Toolchain do
  @moduledoc false

  alias Rekindle.Toolchain.{Error, Process}

  @wasm_bindgen_version "0.2.114"

  @spec wasm_bindgen_version() :: String.t()
  def wasm_bindgen_version, do: @wasm_bindgen_version

  @spec wasm_bindgen_path(String.t(), map()) :: Path.t()
  def wasm_bindgen_path(version \\ @wasm_bindgen_version, environment \\ System.get_env()) do
    Path.join([
      cache_home(environment),
      "rekindle",
      "tools",
      "wasm-bindgen",
      version,
      "bin",
      "wasm-bindgen"
    ])
  end

  @spec resolve_wasm_bindgen(String.t(), keyword()) ::
          {:ok, Path.t()} | {:error, Error.t()}
  def resolve_wasm_bindgen(version \\ @wasm_bindgen_version, options \\ []) do
    path = wasm_bindgen_path(version, Keyword.get(options, :env, System.get_env()))

    if File.regular?(path) do
      verify_wasm_bindgen(path, version, options)
    else
      error(:missing_wasm_bindgen, "wasm-bindgen #{version} is not installed at #{path}")
    end
  end

  @spec install_wasm_bindgen(String.t(), keyword()) ::
          {:ok, Path.t()} | {:error, Error.t()}
  def install_wasm_bindgen(version \\ @wasm_bindgen_version, options \\ []) do
    environment = Keyword.get(options, :env, System.get_env())
    path = wasm_bindgen_path(version, environment)
    root = path |> Path.dirname() |> Path.dirname()
    cargo = Keyword.get(options, :cargo, System.find_executable("cargo") || "cargo")

    arguments = [
      "install",
      "wasm-bindgen-cli",
      "--version",
      "=#{version}",
      "--locked",
      "--root",
      root
    ]

    with :ok <- File.mkdir_p(root),
         {:ok, %{status: 0}} <-
           Process.run(cargo, arguments,
             cd: Keyword.get(options, :cd, File.cwd!()),
             timeout: Keyword.get(options, :timeout, 600_000),
             output_limit: 8_000_000,
             cancel_ref: Keyword.get(options, :cancel_ref),
             env: Keyword.get(options, :process_env, [])
           ) do
      verify_wasm_bindgen(path, version, options)
    else
      {:ok, result} ->
        error(
          :install_failed,
          "cargo install wasm-bindgen-cli #{version} failed with status #{result.status}",
          output: result.output
        )

      {:error, reason} when reason in [:timeout, :cancelled] ->
        process_error(:install_failed, "cargo install wasm-bindgen-cli #{version}", reason)

      {:error, {:start, _reason} = reason} ->
        process_error(:install_failed, "cargo install wasm-bindgen-cli #{version}", reason)

      {:error, reason} ->
        error(
          :cache_unavailable,
          "could not create the wasm-bindgen cache root: #{:file.format_error(reason)}"
        )
    end
  end

  defp verify_wasm_bindgen(path, version, options) do
    case Process.run(path, ["--version"],
           cd: Keyword.get(options, :cd, File.cwd!()),
           timeout: Keyword.get(options, :timeout, 10_000),
           output_limit: 4_096
         ) do
      {:ok, %{status: 0, output: output}} ->
        case String.trim(output) do
          "wasm-bindgen " <> ^version -> {:ok, path}
          actual -> error(:version_mismatch, "expected wasm-bindgen #{version}, got: #{actual}")
        end

      {:ok, result} ->
        error(:version_check_failed, "wasm-bindgen version check failed", output: result.output)

      {:error, reason} ->
        process_error(:version_check_failed, "wasm-bindgen version check", reason)
    end
  end

  defp cache_home(environment) do
    case environment["XDG_CACHE_HOME"] do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute, do: path, else: fallback_cache_home(environment)

      _ ->
        fallback_cache_home(environment)
    end
  end

  defp fallback_cache_home(environment) do
    case environment["HOME"] do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute,
          do: Path.join(path, ".cache"),
          else: Path.join(System.user_home!(), ".cache")

      _ ->
        Path.join(System.user_home!(), ".cache")
    end
  end

  defp process_error(kind, operation, :timeout),
    do: error(kind, "#{operation} timed out")

  defp process_error(kind, operation, :cancelled),
    do: error(kind, "#{operation} was cancelled")

  defp process_error(kind, operation, {:start, reason}),
    do: error(kind, "#{operation} could not start: #{Exception.message(reason)}")

  defp error(kind, message, options \\ []),
    do: {:error, Error.new(kind, message, options)}
end
