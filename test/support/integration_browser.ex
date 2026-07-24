defmodule Rekindle.Test.IntegrationBrowser do
  import ExUnit.Assertions

  alias Rekindle.Integration

  def assert_starts!(artifact, integration, root) do
    browser = System.find_executable("chromium") || flunk("Chromium is required for Web startup")

    driver =
      System.find_executable("chromedriver") ||
        flunk("ChromeDriver is required for Web startup")

    host_root = Path.join(root, "browser")
    profile = Path.join(root, "chromium-profile")
    File.cp_r!(Path.dirname(artifact), host_root)

    {:ok, %{graphics: %{web: graphics}, host: host}} = Integration.fetch(integration)
    File.write!(Path.join(host_root, "index.html"), browser_host(host))

    {:ok, _applications} = Application.ensure_all_started(:inets)

    {:ok, server} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"rekindle",
        server_root: String.to_charlist(host_root),
        document_root: String.to_charlist(host_root),
        modules: [:mod_alias, :mod_dir, :mod_get, :mod_head],
        directory_index: [~c"index.html"],
        mime_types: [
          {~c"html", ~c"text/html"},
          {~c"js", ~c"text/javascript"},
          {~c"wasm", ~c"application/wasm"}
        ]
      )

    port = :httpd.info(server) |> Keyword.fetch!(:port)

    try do
      with_webdriver(driver, browser, profile, graphics, fn webdriver_port, session ->
        webdriver_request!(
          :post,
          webdriver_port,
          "/session/#{session}/url",
          %{"url" => "http://127.0.0.1:#{port}/"}
        )

        baseline =
          webdriver_request!(:get, webdriver_port, "/session/#{session}/screenshot", nil)["value"]

        webdriver_request!(
          :post,
          webdriver_port,
          "/session/#{session}/execute/sync",
          %{"script" => "window.startRekindle(); return null;", "args" => []}
        )

        assert_browser_ready!(webdriver_port, session, integration, baseline)
      end)
    after
      :inets.stop(:httpd, server)
    end
  end

  defp with_webdriver(driver, browser, profile, graphics, function) do
    port = available_port()

    driver_port =
      Port.open(
        {:spawn_executable, String.to_charlist(driver)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"--port=#{port}", ~c"--log-level=SEVERE"]
        ]
      )

    try do
      wait_until!(5_000, fn -> webdriver_available?(port) end, "ChromeDriver did not start")

      response =
        webdriver_request!(:post, port, "/session", %{
          "capabilities" => %{
            "alwaysMatch" => %{
              "browserName" => "chrome",
              "goog:loggingPrefs" => %{"browser" => "ALL"},
              "goog:chromeOptions" => %{
                "binary" => browser,
                "args" => browser_arguments(graphics, profile)
              }
            }
          }
        })

      session = get_in(response, ["value", "sessionId"]) || response["sessionId"]
      assert is_binary(session), "ChromeDriver did not return a session: #{inspect(response)}"

      try do
        function.(port, session)
      after
        webdriver_request(:delete, port, "/session/#{session}", nil)
      end
    after
      Port.close(driver_port)
    end
  end

  defp browser_arguments(:webgpu, profile) do
    common_browser_arguments(profile) ++
      [
        "--enable-unsafe-webgpu",
        "--enable-features=Vulkan",
        "--enable-unsafe-swiftshader",
        "--ignore-gpu-blocklist",
        "--disable-vulkan-surface",
        "--use-angle=vulkan",
        "--use-webgpu-adapter=swiftshader"
      ]
  end

  defp browser_arguments(:webgl2, profile) do
    common_browser_arguments(profile) ++
      [
        "--enable-unsafe-swiftshader",
        "--ignore-gpu-blocklist",
        "--use-gl=angle",
        "--use-angle=swiftshader"
      ]
  end

  defp common_browser_arguments(profile) do
    [
      "--headless=new",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-dev-shm-usage",
      "--user-data-dir=#{profile}"
    ]
  end

  defp assert_browser_ready!(port, session, integration, baseline) do
    result =
      try do
        wait_until!(
          30_000,
          fn ->
            state =
              webdriver_request!(
                :post,
                port,
                "/session/#{session}/execute/sync",
                %{
                  "script" => "return {error: window.rekindleError};",
                  "args" => []
                }
              )["value"]

            screenshot =
              webdriver_request!(:get, port, "/session/#{session}/screenshot", nil)["value"]

            if screenshot != baseline do
              {:ok, :ready}
            else
              {:pending, state}
            end
          end,
          "#{integration} Web startup timed out"
        )
      rescue
        error in ExUnit.AssertionError ->
          logs =
            webdriver_request!(
              :post,
              port,
              "/session/#{session}/se/log",
              %{"type" => "browser"}
            )["value"]

          flunk("#{Exception.message(error)}\nBrowser logs: #{inspect(logs)}")
      end

    assert result == :ready
  end

  defp webdriver_available?(port) do
    match?({:ok, _response}, webdriver_request(:get, port, "/status", nil))
  end

  defp webdriver_request!(method, port, path, body) do
    case webdriver_request(method, port, path, body) do
      {:ok, response} -> response
      {:error, reason} -> flunk("ChromeDriver request failed: #{inspect(reason)}")
    end
  end

  defp webdriver_request(method, port, path, body) do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    request =
      case body do
        nil ->
          {url, []}

        value ->
          {url, [{~c"content-type", ~c"application/json"}], ~c"application/json",
           Jason.encode!(value)}
      end

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response}} when status in 200..299 ->
        {:ok, Jason.decode!(response)}

      {:ok, {{_version, status, _reason}, _headers, response}} ->
        {:error, {:http, status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_until!(timeout, function, message) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until_deadline!(deadline, function, message, nil)
  end

  defp wait_until_deadline!(deadline, function, message, last) do
    case function.() do
      false ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          wait_until_deadline!(deadline, function, message, last)
        else
          flunk("#{message}: #{inspect(last)}")
        end

      {:pending, value} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          wait_until_deadline!(deadline, function, message, value)
        else
          flunk("#{message}: #{inspect(value)}")
        end

      {:ok, result} ->
        result

      {:error, reason} ->
        {:error, reason}

      result ->
        result
    end
  end

  defp browser_host(host) do
    """
    <!doctype html>
    <html>
      <head><meta charset="utf-8"><title>Rekindle startup</title></head>
      <body>
        #{host}
        <script type="module">
          const fail = (error) => {
            const message = String(error?.reason ?? error?.error ?? error);
            window.rekindleError = message;
          };
          window.addEventListener("error", fail);
          window.addEventListener("unhandledrejection", fail);

          window.startRekindle = async () => {
            try {
              if (!window.isSecureContext) throw new Error("insecure context");
              const module = await import("./app.js");
              await module.default();
            } catch (error) {
              fail(error);
            }
          };
        </script>
      </body>
    </html>
    """
  end
end
