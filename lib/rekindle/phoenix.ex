defmodule Rekindle.Phoenix do
  @moduledoc """
  Connects Rekindle's Web artifacts to a Phoenix endpoint.

  The installer adds the development endpoint plug, static delivery, and the
  selected integration's host and module script to the Phoenix root layout.
  `web_entry_path/1` selects the development runtime while code reloading is
  enabled and resolves the production entry module through the application's
  Phoenix static-path implementation otherwise. `web_host/1` supplies the host
  markup required by the selected UI integration when a custom layout needs it.
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
  Returns the Web entry module path for a Phoenix endpoint.

  During code-reloading development, loading this path as a JavaScript module
  starts the current development generation and follows successful rebuilds.
  Otherwise it starts the immutable generation selected by
  `mix rekindle.build web --release`.
  """
  @spec web_entry_path(module()) :: String.t()
  def web_entry_path(endpoint) when is_atom(endpoint) do
    if function_exported?(endpoint, :config, 1) and endpoint.config(:code_reloader) do
      "/__rekindle/runtime.js"
    else
      endpoint.static_path("/rekindle/entry.js")
    end
  end
end
