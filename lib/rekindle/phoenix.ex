defmodule Rekindle.Phoenix do
  @moduledoc """
  Connects Rekindle's Web artifacts to a Phoenix endpoint.

  The installer adds the development endpoint plug and static delivery. In
  production, `web_entry_path/1` resolves the Web entry module through the
  application's Phoenix static-path implementation.
  """

  @doc """
  Returns the Phoenix static path for the Web entry module.

  Loading the returned path as a JavaScript module starts the immutable
  generation selected by `mix rekindle.build web --release`.
  """
  @spec web_entry_path(module()) :: String.t()
  def web_entry_path(endpoint) when is_atom(endpoint) do
    endpoint.static_path("/rekindle/entry.js")
  end
end
