defmodule Rekindle.Toolchain.TargetInstaller do
  @moduledoc false

  alias Rekindle.Failure
  alias Rekindle.Toolchain.{Executable, Rustup}

  @spec ensure(atom(), map(), keyword()) :: {:ok, map()} | {:error, Failure.t()}
  def ensure(target, config, options \\ [])

  def ensure(target, %{backend: {:external, _}}, _options) do
    {:ok, %{target: target, status: :not_required}}
  end

  def ensure(
        target,
        %{backend: :canonical, toolchain: %{kind: :rustup} = toolchain} = config,
        options
      ) do
    with {:ok, rustup} <- Rustup.resolve(),
         :ok <-
           run(
             rustup,
             ["toolchain", "install", toolchain.name, "--profile", "minimal"],
             target,
             options
           ),
         :ok <-
           ensure_rust_target(
             rustup,
             toolchain.name,
             config.rust_target,
             target,
             options
           ) do
      {:ok,
       %{
         target: target,
         status: :verified,
         toolchain: toolchain.name,
         rust_target: config.rust_target
       }}
    end
  end

  def ensure(
        target,
        %{backend: :canonical, toolchain: %{kind: :path} = toolchain} = config,
        options
      ) do
    with {:ok, cargo} <- qualified_executable(toolchain.cargo, target, "cargo"),
         {:ok, rustc} <- qualified_executable(toolchain.rustc, target, "rustc"),
         :ok <- run(cargo, ["-V"], target, options),
         :ok <- run(rustc, ["-Vv"], target, options),
         :ok <- ensure_path_target(rustc, config.rust_target, target, options) do
      {:ok,
       %{
         target: target,
         status: :verified,
         toolchain: toolchain.identity,
         rust_target: config.rust_target
       }}
    end
  end

  defp ensure_rust_target(_rustup, _toolchain, nil, _target, _options), do: :ok

  defp ensure_rust_target(rustup, toolchain, rust_target, target, options) do
    run(rustup, ["target", "add", "--toolchain", toolchain, rust_target], target, options)
  end

  defp ensure_path_target(_rustc, nil, _target, _options), do: :ok

  defp ensure_path_target(rustc, rust_target, target, options) do
    case Executable.run(
           rustc,
           ["--print", "target-libdir", "--target", rust_target],
           options
         ) do
      {:ok, {path, 0}} ->
        if File.dir?(String.trim(path)) do
          :ok
        else
          failure(target, :tool_missing, "declared Rust target is unavailable")
        end

      _other ->
        failure(target, :tool_missing, "declared Rust target is unavailable")
    end
  rescue
    _ -> failure(target, :tool_missing, "declared Rust target is unavailable")
  end

  defp qualified_executable(path, target, name) do
    case Executable.qualify(path) do
      {:ok, executable} ->
        {:ok, executable}

      {:error, _reason} ->
        failure(target, :tool_missing, "qualified #{name} executable is unavailable")
    end
  end

  defp run(executable, argv, target, options) do
    case Executable.run(executable, argv, options) do
      {:ok, {_output, 0}} ->
        :ok

      _other ->
        failure(target, :tool_missing, "qualified Rust toolchain setup failed")
    end
  rescue
    _ -> failure(target, :tool_missing, "qualified Rust toolchain setup failed")
  end

  defp failure(target, code, message) do
    {:error, Failure.new!(target: target, stage: :compatibility, code: code, message: message)}
  end
end
