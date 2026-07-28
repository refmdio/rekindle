defmodule Rekindle.Phoenix do
  @moduledoc """
  Connects Rekindle's Web artifacts to a Phoenix endpoint.

  The installer adds the development endpoint plug, static delivery, and the
  selected plugin's Web shell and module script to the Phoenix root
  layout.
  `web_entry_path/1` selects the development runtime while code reloading is
  enabled and resolves the production entry module through the application's
  Phoenix static-path implementation otherwise. `web_host/1` and `web_style/1`
  supply the plugin-owned shell when a custom layout needs it.
  """

  @type plugin :: Rekindle.Plugin.configured()

  @doc false
  @spec public_root(atom()) :: Path.t()
  def public_root(otp_app) do
    config = Application.get_env(otp_app, Rekindle, [])
    public_dir = Keyword.get(config, :public_dir, "priv/static")

    root =
      if public_dir == "priv/static",
        do: Application.app_dir(otp_app, public_dir),
        else: public_dir

    Path.join(root, "rekindle")
  end

  @doc """
  Returns the Web host markup declared by a plugin.

  GPUI does not require a host element. The built-in egui and Slint plugins
  return their required canvas elements. Applications can render markup from a
  trusted configured plugin with `Phoenix.HTML.raw/1`.
  """
  @spec web_host(plugin()) :: String.t()
  def web_host(plugin), do: Rekindle.Plugin.spec(plugin).web.host

  @doc """
  Returns the Web shell CSS declared by a plugin.

  The generated Phoenix layout places this CSS in its document head so the
  browser target occupies the same application surface as its desktop target.
  """
  @spec web_style(plugin()) :: String.t()
  def web_style(plugin), do: Rekindle.Plugin.spec(plugin).web.style

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
