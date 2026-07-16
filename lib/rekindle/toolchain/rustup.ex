defmodule Rekindle.Toolchain.Rustup do
  @moduledoc false

  alias Rekindle.Failure
  alias Rekindle.Toolchain.Executable

  @spec resolve() :: {:ok, Executable.t()} | {:error, Failure.t()}
  def resolve do
    candidates =
      case System.get_env("REKINDLE_RUSTUP") do
        nil -> [Path.join(System.user_home!(), ".cargo/bin/rustup")]
        override -> [override]
      end

    case Enum.find_value(candidates, &qualified_executable/1) do
      nil ->
        {:error,
         Failure.new!(
           target: nil,
           stage: :compatibility,
           code: :tool_missing,
           message: "qualified rustup executable is unavailable"
         )}

      executable ->
        {:ok, executable}
    end
  end

  @spec resolve!() :: Executable.t()
  def resolve! do
    case resolve() do
      {:ok, executable} -> executable
      {:error, failure} -> raise failure.message
    end
  end

  defp qualified_executable(path) when is_binary(path) do
    expanded = Path.expand(path)

    if Path.type(path) == :absolute do
      case Executable.qualify(expanded) do
        {:ok, executable} -> executable
        {:error, _reason} -> nil
      end
    else
      nil
    end
  end

  defp qualified_executable(_path), do: nil
end
