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
  alias Rekindle.Development.State
  alias Rekindle.Web.Manifest

  @prefix ["__rekindle"]
  @generation ~r/\A[0-9a-f]{32}\z/

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
         {:ok, integration} <- Rekindle.Integration.fetch(project.integration) do
      conn
      |> no_store()
      |> put_resp_content_type("text/javascript")
      |> send_resp(200, runtime(integration.graphics.web))
      |> halt()
    else
      _error -> unavailable(conn)
    end
  end

  defp dispatch(
         %Plug.Conn{method: "GET", path_info: @prefix ++ ["current"]} = conn,
         options
       ) do
    with {:ok, project} <- project(options) do
      case State.build_error(project) do
        {:ok, message} ->
          json(conn, 409, %{"error" => message})

        :none ->
          case current(project) do
            {:ok, selection} ->
              json(conn, 200, %{
                "generation" => selection.generation,
                "entry" => path(selection.generation, selection.entry)
              })

            _error ->
              unavailable(conn)
          end
      end
    else
      _error -> unavailable(conn)
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
         {:ok, manifest} <- manifest(project, generation),
         root = Path.join([project.root, ".rekindle", "dev", "web", generation]),
         {:ok, contents} <- Manifest.read_member(root, manifest, requested) do
      conn
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_content_type(MIME.from_path(requested))
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

  defp current(project) do
    selector_path = Path.join([project.root, ".rekindle", "dev", "web-current.json"])

    with {:ok, contents} <- File.read(selector_path),
         {:ok, %{"generation" => generation}} <- Jason.decode(contents),
         true <- Regex.match?(@generation, generation),
         {:ok, manifest} <- manifest(project, generation) do
      {:ok, %{generation: generation, entry: manifest["entry"]}}
    end
  end

  defp manifest(project, generation) do
    root = Path.join([project.root, ".rekindle", "dev", "web", generation])

    with {:ok, %{"generation" => ^generation, "entry" => entry} = manifest} <-
           Manifest.read(root),
         true <- safe_member?(entry),
         :ok <- Manifest.validate(root, manifest) do
      {:ok, manifest}
    end
  end

  defp safe_member?(member) when is_binary(member) and member != "" do
    root = "/generation"
    expanded = Path.expand(member, root)

    Path.type(member) == :relative and expanded != root and
      String.starts_with?(expanded, root <> "/") and
      Path.relative_to(expanded, root) == member
  end

  defp safe_member?(_member), do: false

  defp path(generation, entry), do: "/__rekindle/web/#{generation}/#{entry}"

  defp runtime(graphics) do
    """
    const currentUrl = new URL("./current", import.meta.url);
    const statusView = ensureStatusView();
    const errorView = ensureErrorView();
    let activeGeneration;
    let attemptedGeneration;
    let reportedError;
    let loading = false;
    let reloading = false;

    function ensureStatusView() {
      const existing = document.getElementById("rekindle-status");
      if (existing) return existing;

      const view = document.createElement("div");
      view.id = "rekindle-status";
      view.setAttribute("role", "status");
      view.setAttribute("aria-live", "polite");
      view.textContent = "Building Rust UI\u2026";
      Object.assign(view.style, {
        boxSizing: "border-box",
        padding: "1rem",
        fontFamily: "system-ui, sans-serif"
      });
      document.body.appendChild(view);
      return view;
    }

    function ensureErrorView() {
      const existing = document.getElementById("rekindle-error");
      if (existing) return existing;

      const view = document.createElement("pre");
      view.id = "rekindle-error";
      view.hidden = true;
      view.setAttribute("role", "alert");
      Object.assign(view.style, {
        boxSizing: "border-box",
        margin: "0",
        padding: "1rem",
        whiteSpace: "pre-wrap"
      });
      document.body.appendChild(view);
      return view;
    }

    function report(error, key) {
      const message = error instanceof Error ? error.message : String(error);
      const identity = key ?? message;
      if (reportedError === identity) return;
      reportedError = identity;
      console.error("[rekindle]", error);
      statusView.hidden = true;
      errorView.textContent = message;
      errorView.hidden = false;
      window.dispatchEvent(new CustomEvent("rekindle:error", {detail: {message}}));
    }

    function clearError() {
      reportedError = undefined;
      errorView.hidden = true;
    }

    async function graphicsReady() {
      #{graphics_check(graphics)}
    }

    async function update() {
      if (loading || reloading) return;
      loading = true;
      let candidateGeneration;

      try {
        const response = await fetch(currentUrl, {cache: "no-store"});
        if (response.status === 409) {
          const failure = await response.json();
          report(new Error(failure.error), `build:${failure.error}`);
          return;
        }
        if (!response.ok) return;
        const current = await response.json();
        candidateGeneration = current.generation;

        if (activeGeneration && activeGeneration !== current.generation) {
          reloading = true;
          window.dispatchEvent(new CustomEvent("rekindle:before-reload", {
            detail: {from: activeGeneration, to: current.generation}
          }));
          window.location.reload();
          return;
        }

        if (!activeGeneration) {
          if (attemptedGeneration === current.generation) return;
          attemptedGeneration = current.generation;
          statusView.textContent = "Starting Rust UI\u2026";
          statusView.hidden = false;
          await graphicsReady();
          const module = await import(current.entry);
          if (typeof module.default !== "function") {
            throw new Error("The Web entry does not export a wasm-bindgen initializer.");
          }
          await module.default();
          activeGeneration = current.generation;
          window.dispatchEvent(new CustomEvent("rekindle:ready", {
            detail: {generation: activeGeneration}
          }));
        }
        statusView.hidden = true;
        clearError();
      } catch (error) {
        const key = candidateGeneration
          ? `startup:${candidateGeneration}:${String(error)}`
          : `runtime:${String(error)}`;
        report(error, key);
      } finally {
        loading = false;
      }
    }

    update();
    window.setInterval(update, 250);
    """
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

  defp json(conn, status, body) do
    conn
    |> no_store()
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

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
