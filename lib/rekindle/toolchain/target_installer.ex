defmodule Rekindle.Toolchain.TargetInstaller do
  @moduledoc false

  alias Rekindle.Failure
  alias Rekindle.Toolchain.Rustup

  @spec ensure(atom(), map()) :: {:ok, map()} | {:error, Failure.t()}
  def ensure(target, %{backend: {:external, _}}) do
    {:ok, %{target: target, status: :not_required}}
  end

  def ensure(target, %{backend: :canonical, toolchain: %{kind: :rustup} = toolchain} = config) do
    with {:ok, rustup} <- Rustup.resolve(),
         :ok <-
           run(rustup, ["toolchain", "install", toolchain.name, "--profile", "minimal"], target),
         :ok <- ensure_rust_target(rustup, toolchain.name, config.rust_target, target) do
      {:ok,
       %{
         target: target,
         status: :verified,
         toolchain: toolchain.name,
         rust_target: config.rust_target
       }}
    end
  end

  def ensure(target, %{backend: :canonical, toolchain: %{kind: :path} = toolchain} = config) do
    with :ok <- qualified_executable(toolchain.cargo, target, "cargo"),
         :ok <- qualified_executable(toolchain.rustc, target, "rustc"),
         :ok <- run(toolchain.cargo, ["-V"], target),
         :ok <- run(toolchain.rustc, ["-Vv"], target),
         :ok <- ensure_path_target(toolchain.rustc, config.rust_target, target) do
      {:ok,
       %{
         target: target,
         status: :verified,
         toolchain: toolchain.identity,
         rust_target: config.rust_target
       }}
    end
  end

  defp ensure_rust_target(_rustup, _toolchain, nil, _target), do: :ok

  defp ensure_rust_target(rustup, toolchain, rust_target, target) do
    run(rustup, ["target", "add", "--toolchain", toolchain, rust_target], target)
  end

  defp ensure_path_target(_rustc, nil, _target), do: :ok

  defp ensure_path_target(rustc, rust_target, target) do
    case System.cmd(rustc, ["--print", "target-libdir", "--target", rust_target],
           stderr_to_stdout: true
         ) do
      {path, 0} ->
        if File.dir?(String.trim(path)) do
          :ok
        else
          failure(target, :tool_missing, "declared Rust target is unavailable")
        end

      {_output, _status} ->
        failure(target, :tool_missing, "declared Rust target is unavailable")
    end
  rescue
    _ -> failure(target, :tool_missing, "declared Rust target is unavailable")
  end

  defp qualified_executable(path, target, name) do
    with true <- is_binary(path) and Path.type(path) == :absolute,
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         true <- Bitwise.band(stat.mode, 0o111) != 0 do
      :ok
    else
      _ -> failure(target, :tool_missing, "qualified #{name} executable is unavailable")
    end
  end

  defp run(executable, argv, target) do
    case System.cmd(executable, argv, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {_output, _status} ->
        failure(target, :tool_missing, "qualified Rust toolchain setup failed")
    end
  rescue
    _ -> failure(target, :tool_missing, "qualified Rust toolchain setup failed")
  end

  defp failure(target, code, message) do
    {:error, Failure.new!(target: target, stage: :compatibility, code: code, message: message)}
  end
end
