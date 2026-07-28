defmodule Rekindle.Priv do
  @moduledoc """
  Resolves files owned by an OTP application's `priv` directory.

  Plugins can keep Rust and UI source files in their own package and identify
  the common root with an `{app, root}` tuple.
  """

  @type source :: atom() | {atom(), String.t()}

  @spec path(source(), String.t()) :: String.t()
  def path({app, root}, relative)
      when is_atom(app) and is_binary(root) and is_binary(relative) do
    Application.app_dir(
      app,
      Path.join(["priv", clean_relative!(root), clean_relative!(relative)])
    )
  end

  def path(app, relative) when is_atom(app) and is_binary(relative) do
    Application.app_dir(app, Path.join("priv", clean_relative!(relative)))
  end

  @spec read!(source(), String.t()) :: String.t()
  def read!(source, relative) do
    source
    |> path(relative)
    |> File.read!()
  end

  defp clean_relative!(path) do
    cond do
      Path.type(path) == :absolute ->
        raise ArgumentError, "priv paths must be relative, got: #{inspect(path)}"

      path |> Path.split() |> Enum.member?("..") ->
        raise ArgumentError, "priv paths cannot contain .. segments, got: #{inspect(path)}"

      true ->
        path
    end
  end
end
