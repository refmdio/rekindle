defmodule Rekindle.Toolchain do
  @moduledoc false

  alias Rekindle.Toolchain.{Error, Process}

  @wasm_bindgen_version "0.2.126"

  @spec wasm_bindgen_version() :: String.t()
  def wasm_bindgen_version, do: @wasm_bindgen_version

  @spec cargo_path(keyword()) :: Path.t()
  def cargo_path(options \\ []) do
    Keyword.get(options, :cargo) ||
      rustup_tool_path("cargo", options) ||
      System.find_executable("cargo") ||
      "cargo"
  end

  @spec rustc_path(keyword()) :: Path.t()
  def rustc_path(options \\ []) do
    Keyword.get(options, :rustc) ||
      rustup_tool_path("rustc", options) ||
      System.find_executable("rustc") ||
      "rustc"
  end

  @spec cargo_environment(keyword(), atom()) :: [{String.t(), String.t()}]
  def cargo_environment(options, key \\ :env) do
    environment = options |> Keyword.get(key, []) |> Map.new()
    directory = Keyword.get(options, :cd, File.cwd!())

    environment =
      cond do
        rustc = Keyword.get(options, :rustc) ->
          Map.put(environment, "RUSTC", rustc)

        environment["RUSTC"] ->
          environment

        project_toolchain?(directory) ->
          Map.put(environment, "RUSTC", rustc_path(options))

        true ->
          environment
      end

    if project_toolchain?(directory) do
      path = environment["PATH"] || System.get_env("PATH", "")
      toolchain_bin = options |> cargo_path() |> Path.dirname()
      path = if path == "", do: toolchain_bin, else: toolchain_bin <> path_separator() <> path
      Map.put(environment, "PATH", path)
    else
      environment
    end
    |> Map.to_list()
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
    rustc = rustc_path(options)

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
             env: cargo_environment(options, :process_env)
           ) do
      verify_wasm_bindgen(path, version, options)
    else
      {:ok, result} ->
        error(
          :install_failed,
          "cargo install wasm-bindgen-cli #{version} failed with status #{result.status}",
          output: result.output
        )

      {:error, :timeout} ->
        process_error(:install_failed, "cargo install wasm-bindgen-cli #{version}", :timeout)

      {:error, :output_limit} ->
        process_error(
          :install_failed,
          "cargo install wasm-bindgen-cli #{version}",
          :output_limit
        )

      {:error, {:start, _reason} = reason} ->
        process_error(:install_failed, "cargo install wasm-bindgen-cli #{version}", reason)

      {:error, {:invalid_option, _option} = reason} ->
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

  defp rustup_tool_path(tool, options) do
    rustup = rustup_path(options)
    directory = Keyword.get(options, :cd, File.cwd!())

    if project_toolchain?(directory) do
      fallback = rustup |> Path.expand(directory) |> Path.dirname() |> Path.join(tool)

      if Path.type(rustup) == :absolute and File.regular?(rustup) do
        case Process.run(rustup, ["which", tool],
               cd: directory,
               timeout: Keyword.get(options, :timeout, 30_000),
               output_limit: 4_096,
               env: Keyword.get(options, :process_env, [])
             ) do
          {:ok, %{status: 0, output: output}} ->
            path = String.trim(output)

            if Path.type(path) == :absolute and File.regular?(path), do: path, else: fallback

          _ ->
            fallback
        end
      else
        fallback
      end
    end
  end

  defp project_toolchain?(directory) do
    File.regular?(Path.join(directory, "rust-toolchain.toml")) or
      File.regular?(Path.join(directory, "rust-toolchain"))
  end

  defp path_separator do
    case :os.type() do
      {:win32, _name} -> ";"
      _type -> ":"
    end
  end

  defp check_cargo_version(path, options) do
    case Process.run(path, ["--version"],
           cd: Keyword.get(options, :cd, File.cwd!()),
           timeout: Keyword.get(options, :timeout, 30_000),
           output_limit: 4_096,
           env: Keyword.get(options, :process_env, [])
         ) do
      {:ok, %{status: 0, output: output}} ->
        parse_cargo_version(path, output)

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

  defp process_error(kind, operation, :output_limit),
    do: error(kind, "#{operation} exceeded the output limit")

  defp process_error(kind, operation, {:start, reason}),
    do: error(kind, "#{operation} could not start: #{Exception.message(reason)}")

  defp process_error(_kind, operation, {:invalid_option, option}),
    do: error(:invalid_option, "invalid #{operation} process option: #{option}")

  defp error(kind, message, options \\ []),
    do: {:error, Error.new(kind, message, options)}
end
