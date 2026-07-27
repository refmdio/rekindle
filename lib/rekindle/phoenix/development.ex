defmodule Rekindle.Phoenix.Development do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Rekindle.Config
  alias Rekindle.OwnedPath
  alias Rekindle.Publication
  alias Rekindle.Web.Manifest

  @prefix ["__rekindle"]
  @generation ~r/\A[0-9a-f]{64}\z/

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(
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

  def call(%Plug.Conn{method: "GET", path_info: @prefix ++ ["current"]} = conn, options) do
    with {:ok, project} <- project(options) do
      case build_error(project) do
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

  def call(
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

  def call(conn, _options), do: conn

  @doc false
  @spec put_error(Config.t(), String.t()) :: :ok
  def put_error(project, message) do
    path = error_path(project)

    with :ok <- OwnedPath.ensure_directory(project.root, Path.dirname(path)),
         {:ok, temporary} <-
           Publication.temporary_file(Path.dirname(path), ".tmp-web-error-") do
      try do
        with :ok <- File.write(temporary, Jason.encode!(%{"error" => message})),
             :ok <- File.rename(temporary, path) do
          :ok
        else
          {:error, _reason} -> :ok
        end
      after
        OwnedPath.remove_file(project.root, temporary)
      end
    else
      {:error, _reason} -> :ok
    end
  end

  @doc false
  @spec clear_error(Config.t()) :: :ok
  def clear_error(project) do
    case OwnedPath.remove_file(project.root, error_path(project)) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp project(options) do
    Config.load(
      Keyword.fetch!(options, :otp_app),
      project_root: Keyword.get(options, :project_root, File.cwd!())
    )
  end

  defp current(project) do
    selector_path = Path.join([project.root, ".rekindle", "dev", "web-current.json"])

    with {:ok, contents} <- OwnedPath.read_file(project.root, selector_path),
         {:ok, %{"generation" => generation}} <- Jason.decode(contents),
         true <- Regex.match?(@generation, generation),
         {:ok, manifest} <- manifest(project, generation) do
      {:ok, %{generation: generation, entry: manifest["entry"]}}
    end
  end

  defp manifest(project, generation) do
    root = Path.join([project.root, ".rekindle", "dev", "web", generation])

    with :ok <- OwnedPath.validate_directory(project.root, root),
         {:ok,
          %{
            "generation" => ^generation,
            "entry" => entry,
            "members" => members
          } = manifest} <- Manifest.read(root),
         true <- safe_member?(entry),
         true <- is_list(members),
         true <- Enum.any?(members, &(&1["path"] == entry)) do
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

  defp build_error(project) do
    path = error_path(project)

    with {:ok, contents} <- OwnedPath.read_file(project.root, path),
         {:ok, %{"error" => message}} when is_binary(message) <- Jason.decode(contents) do
      {:ok, message}
    else
      _error -> :none
    end
  end

  defp error_path(project), do: Path.join([project.root, ".rekindle", "dev", "web-error.json"])

  defp path(generation, entry), do: "/__rekindle/web/#{generation}/#{entry}"

  defp runtime(graphics) do
    """
    const currentUrl = new URL("./current", import.meta.url);
    const errorView = ensureErrorView();
    let activeGeneration;
    let loading = false;

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

    function report(error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error("[rekindle]", error);
      errorView.textContent = message;
      errorView.hidden = false;
    }

    async function graphicsReady() {
      #{graphics_check(graphics)}
    }

    async function update() {
      if (loading) return;
      loading = true;

      try {
        const response = await fetch(currentUrl, {cache: "no-store"});
        if (response.status === 409) {
          const failure = await response.json();
          report(new Error(failure.error));
          return;
        }
        if (!response.ok) return;
        const current = await response.json();

        if (activeGeneration && activeGeneration !== current.generation) {
          window.location.reload();
          return;
        }

        if (!activeGeneration) {
          await graphicsReady();
          const module = await import(current.entry);
          if (typeof module.default !== "function") {
            throw new Error("The Web entry does not export a wasm-bindgen initializer.");
          }
          await module.default();
          activeGeneration = current.generation;
        }
        errorView.hidden = true;
      } catch (error) {
        report(error);
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
