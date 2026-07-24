defmodule Rekindle.Phoenix do
  @moduledoc """
  Connects Rekindle's Web artifacts to a Phoenix endpoint.

  The installer adds the development endpoint plug and static delivery. In
  production, `web_entry_path/1` resolves the selected Web generation through
  the application's Phoenix static-path implementation.
  """

  @doc """
  Returns the Phoenix static path for the selected Web generation descriptor.

  The returned JSON path identifies the immutable generated module and
  manifest published by `mix rekindle.build web --release`.
  """
  @spec web_entry_path(module()) :: String.t()
  def web_entry_path(endpoint) when is_atom(endpoint) do
    endpoint.static_path("/rekindle/web-current.json")
  end
end
