defmodule Rekindle.DevServer do
  @moduledoc """
  Plug that serves Rekindle Web generations during development.

  Add it to a Plug pipeline with the OTP application that owns the Rekindle
  configuration:

      plug Rekindle.DevServer, otp_app: :my_app

  The first request starts the Web development runtime unless `watch: false` is
  supplied. The Phoenix installer adds this Plug automatically.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Rekindle.Config
  alias Rekindle.Development
  alias Rekindle.Development.Socket

  @prefix ["__rekindle"]
  @generation ~r/\A[0-9a-f]{32}\z/
  @browser_log_domain [:rekindle, :browser]
  @browser_log_event_domain [:elixir | @browser_log_domain]
  @live_reload_logger Phoenix.LiveReloader.WebConsoleLogger
  @live_reload_filter :rekindle_browser_console
  @runtime_path Path.expand("../../priv/runtime/dev_server.js", __DIR__)
  @external_resource @runtime_path
  @runtime File.read!(@runtime_path)
  @graphics_placeholder "/* __REKINDLE_GRAPHICS_CHECK__ */"

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, options) do
    ensure_development(options)
    dispatch(conn, options)
  end

  defp dispatch(
         %Plug.Conn{method: "GET", path_info: @prefix ++ ["runtime.js"]} = conn,
         options
       ) do
    with {:ok, project} <- project(options),
         {:ok, {_module, _plugin_options, plugin}} <- Rekindle.Plugin.load(project.plugin) do
      conn
      |> no_store()
      |> put_resp_content_type("text/javascript")
      |> send_resp(200, runtime(plugin.web.graphics))
      |> halt()
    else
      _error -> unavailable(conn)
    end
  end

  defp dispatch(
         %Plug.Conn{method: "GET", path_info: @prefix ++ ["socket"]} = conn,
         options
       ) do
    with {:ok, project} <- project(options) do
      conn
      |> WebSockAdapter.upgrade(Socket, project, timeout: :infinity)
      |> halt()
    else
      _error -> unavailable(conn)
    end
  rescue
    WebSockAdapter.UpgradeError ->
      conn
      |> no_store()
      |> put_resp_header("upgrade", "websocket")
      |> send_resp(426, "WebSocket upgrade required")
      |> halt()
  end

  defp dispatch(
         %Plug.Conn{method: "POST", path_info: @prefix ++ ["console"]} = conn,
         _options
       ) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, payload} <- Jason.decode(body),
         {:ok, level, message} <- browser_console_message(payload) do
      suppress_live_reload_echo()
      Logger.log(level, message, domain: @browser_log_domain)

      conn
      |> no_store()
      |> send_resp(204, "")
      |> halt()
    else
      _error ->
        conn
        |> no_store()
        |> send_resp(400, "Invalid browser console message")
        |> halt()
    end
  end

  defp dispatch(
         %Plug.Conn{
           method: "GET",
           path_info: @prefix ++ ["web", generation | member]
         } = conn,
         options
       ) do
    requested = Enum.join(member, "/")

    with true <- Regex.match?(@generation, generation),
         true <- safe_member?(requested),
         {:ok, project} <- project(options),
         root = Path.join([project.root, ".rekindle", "dev", "web", generation]),
         {:ok, contents} <- File.read(Path.join(root, requested)) do
      conn
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_asset_content_type(requested)
      |> send_resp(200, contents)
      |> halt()
    else
      _error -> not_found(conn)
    end
  end

  defp dispatch(conn, _options), do: conn

  defp project(options) do
    Config.load(
      Keyword.fetch!(options, :otp_app),
      project_root: Keyword.get(options, :project_root, File.cwd!())
    )
  end

  defp ensure_development(options) do
    if Keyword.get(options, :watch, true) do
      development_options =
        options
        |> Keyword.take([:otp_app, :project_root])
        |> Keyword.put(:targets, [:web])

      case Development.ensure_started(development_options) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "could not start Rekindle Web development runtime: #{error_message(reason)}"
          )
      end
    end
  end

  defp error_message(reason) do
    if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
  end

  defp safe_member?(member) when is_binary(member) and member != "" do
    root = "/generation"
    expanded = Path.expand(member, root)

    Path.type(member) == :relative and expanded != root and
      String.starts_with?(expanded, root <> "/") and
      Path.relative_to(expanded, root) == member
  end

  defp safe_member?(_member), do: false

  defp browser_console_message(%{
         "level" => browser_level,
         "source" => source,
         "args" => args
       })
       when browser_level in ["log", "info", "warn", "error", "debug"] and
              source in ["console", "error", "unhandledrejection"] and is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      level =
        case browser_level do
          level when level in ["log", "info"] -> :info
          "warn" -> :warning
          "error" -> :error
          "debug" -> :debug
        end

      {:ok, level, ["[browser ", source, "] ", Enum.intersperse(args, " ")]}
    else
      :error
    end
  end

  defp browser_console_message(_payload), do: :error

  defp suppress_live_reload_echo do
    for %{id: id, module: @live_reload_logger, filters: filters} <-
          :logger.get_handler_config(),
        not Keyword.has_key?(filters, @live_reload_filter) do
      :logger.add_handler_filter(
        id,
        @live_reload_filter,
        {&:logger_filters.domain/2, {:stop, :equal, @browser_log_event_domain}}
      )
    end

    :ok
  end

  defp put_asset_content_type(conn, path) do
    if Path.extname(path) == ".wasm" do
      put_resp_header(conn, "content-type", "application/wasm")
    else
      put_resp_content_type(conn, MIME.from_path(path))
    end
  end

  defp runtime(graphics) do
    String.replace(@runtime, @graphics_placeholder, graphics_check(graphics))
  end

  defp graphics_check(:webgpu) do
    """
    if (!window.isSecureContext) {
      throw new Error("WebGPU requires HTTPS or a loopback origin.");
    }
    if (!navigator.gpu) {
      throw new Error("This browser does not expose WebGPU.");
    }
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
      throw new Error("No WebGPU graphics adapter is available.");
    }
    """
  end

  defp graphics_check(:webgl2) do
    """
    const probe = document.createElement("canvas");
    if (!probe.getContext("webgl2")) {
      throw new Error("No WebGL2 graphics context is available.");
    }
    """
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")

  defp unavailable(conn) do
    conn
    |> no_store()
    |> send_resp(503, "Rekindle Web output is not available")
    |> halt()
  end

  defp not_found(conn) do
    conn
    |> send_resp(404, "Not found")
    |> halt()
  end
end
