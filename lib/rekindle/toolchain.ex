defmodule Rekindle.Toolchain do
  @moduledoc false

  alias Rekindle.Toolchain.{Error, Process}

  @wasm_bindgen_version "0.2.126"

  @spec wasm_bindgen_version() :: String.t()
  def wasm_bindgen_version, do: @wasm_bindgen_version

  @spec cargo_path(keyword()) :: Path.t()
  def cargo_path(options \\ []) do
    Keyword.get(options, :cargo) || System.find_executable("cargo") || "cargo"
  end

  @spec cargo_version(keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def cargo_version(options \\ []) do
    path = cargo_path(options)

    if Path.type(path) == :absolute and File.regular?(path) do
      check_cargo_version(path, options)
    else
      error(:missing_cargo, "cargo executable was not found")
    end
  end

  @spec rustup_path(keyword()) :: Path.t()
  def rustup_path(options \\ []) do
    Keyword.get(options, :rustup) || System.find_executable("rustup") || "rustup"
  end

  @spec host_target(keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def host_target(options \\ []) do
    rustc = Keyword.get(options, :rustc) || System.find_executable("rustc") || "rustc"

    case Process.run(rustc, ["-vV"],
           cd: Keyword.get(options, :cd, File.cwd!()),
           timeout: Keyword.get(options, :timeout, 30_000),
           output_limit: 16_000
         ) do
      {:ok, %{status: 0, output: output}} ->
        case Regex.run(~r/^host:\s+(\S+)$/m, output) do
          [_, target] -> {:ok, target}
          _ -> error(:invalid_rustc, "rustc did not report its host target")
        end

      {:ok, result} ->
        error(:invalid_rustc, "rustc host detection failed", output: result.output)

      {:error, reason} ->
        process_error(:invalid_rustc, "rustc host detection", reason)
    end
  end

  @spec target(:web | :desktop, keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def target(name, options \\ [])
  def target(:web, _options), do: {:ok, "wasm32-unknown-unknown"}
  def target(:desktop, options), do: host_target(options)

  @spec installed_rust_targets(keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def installed_rust_targets(options \\ []) do
    case Process.run(rustup_path(options), ["target", "list", "--installed"],
           cd: Keyword.get(options, :cd, File.cwd!()),
           timeout: Keyword.get(options, :timeout, 30_000),
           output_limit: 64_000,
           env: Keyword.get(options, :process_env, [])
         ) do
      {:ok, %{status: 0, output: output}} ->
        {:ok, String.split(output, ~r/\s+/, trim: true)}

      {:ok, result} ->
        error(:rustup_failed, "rustup target list failed", output: result.output)

      {:error, reason} ->
        process_error(:rustup_failed, "rustup target list", reason)
    end
  end

  @spec install_rust_target(String.t(), keyword()) :: :ok | {:error, Error.t()}
  def install_rust_target(target, options \\ []) do
    case Process.run(rustup_path(options), ["target", "add", target],
           cd: Keyword.get(options, :cd, File.cwd!()),
           timeout: Keyword.get(options, :timeout, 600_000),
           output_limit: 8_000_000,
           cancel_ref: Keyword.get(options, :cancel_ref),
           env: Keyword.get(options, :process_env, [])
         ) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, result} ->
        error(:rust_target_install_failed, "rustup target add #{target} failed",
          output: result.output
        )

      {:error, reason} ->
        process_error(:rust_target_install_failed, "rustup target add #{target}", reason)
    end
  end

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
    cargo = cargo_path(options)

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

  defp check_cargo_version(path, options) do
    case Process.run(path, ["--version"],
           cd: Keyword.get(options, :cd, File.cwd!()),
           timeout: Keyword.get(options, :timeout, 30_000),
           output_limit: 4_096,
           env: Keyword.get(options, :process_env, [])
         ) do
      {:ok, %{status: 0, output: output, truncated?: false}} ->
        parse_cargo_version(path, output)

      {:ok, %{truncated?: true}} ->
        error(:cargo_not_ready, "cargo at #{path} returned an oversized version response")

      {:ok, result} ->
        error(
          :cargo_not_ready,
          "cargo at #{path} failed its readiness check with status #{result.status}",
          output: result.output
        )

      {:error, reason} ->
        process_error(:cargo_not_ready, "cargo at #{path} failed its readiness check", reason)
    end
  end

  defp parse_cargo_version(path, output) do
    case output |> String.trim() |> String.split(~r/\s+/, trim: true) do
      ["cargo", version | _rest] ->
        case Version.parse(version) do
          {:ok, _version} -> {:ok, version}
          :error -> invalid_cargo_version(path, output)
        end

      _ ->
        invalid_cargo_version(path, output)
    end
  end

  defp invalid_cargo_version(path, output) do
    reported = String.trim(output)
    suffix = if reported == "", do: "", else: "; reported: #{reported}"

    error(:cargo_not_ready, "cargo at #{path} returned an invalid version#{suffix}",
      output: output
    )
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
