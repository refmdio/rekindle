defmodule Rekindle.Phoenix do
  @moduledoc """
  Connects Rekindle's Web artifacts to a Phoenix endpoint.

  The installer adds the development endpoint plug and static delivery. In
  production, `web_entry_path/1` resolves the Web entry module through the
  application's Phoenix static-path implementation. `web_host/1` supplies the
  host markup required by the selected UI integration.
  """

  @type integration :: :gpui | :egui | :slint

  @doc """
  Returns the trusted Web host markup for a built-in integration.

  GPUI does not require a host element. egui and Slint return their required
  canvas elements. The returned markup is fixed by Rekindle and can be rendered
  with `Phoenix.HTML.raw/1`.
  """
  @spec web_host(integration()) :: String.t()
  def web_host(integration), do: Rekindle.Integration.host(integration)

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
