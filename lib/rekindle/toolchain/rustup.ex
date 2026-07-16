defmodule Rekindle.Toolchain.Rustup do
  @moduledoc false

  alias Rekindle.Failure

  @spec resolve() :: {:ok, Path.t()} | {:error, Failure.t()}
  def resolve do
    candidates =
      case System.get_env("REKINDLE_RUSTUP") do
        nil -> [Path.join(System.user_home!(), ".cargo/bin/rustup")]
        override -> [override]
      end

    case Enum.find_value(candidates, &qualified_path/1) do
      nil ->
        {:error,
         Failure.new!(
           target: nil,
           stage: :compatibility,
           code: :tool_missing,
           message: "qualified rustup executable is unavailable"
         )}

      path ->
        {:ok, path}
    end
  end

  @spec resolve!() :: Path.t()
  def resolve! do
    case resolve() do
      {:ok, path} -> path
      {:error, failure} -> raise failure.message
    end
  end

  defp qualified_path(path) when is_binary(path) do
    expanded = Path.expand(path)

    with true <- Path.type(path) == :absolute,
         {:ok, stat} <- File.stat(expanded),
         true <- stat.type == :regular,
         true <- Bitwise.band(stat.mode, 0o111) != 0 do
      expanded
    else
      _ -> nil
    end
  end

  defp qualified_path(_path), do: nil
end
