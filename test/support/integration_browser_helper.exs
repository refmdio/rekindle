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

        webdriver_request!(
          :post,
          webdriver_port,
          "/session/#{session}/execute/sync",
          %{"script" => "window.startRekindle(); return null;", "args" => []}
        )

        assert_browser_ready!(webdriver_port, session, integration)
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
      webdriver_request(:get, port, "/shutdown", nil)
      if Port.info(driver_port), do: Port.close(driver_port)
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

  @doc false
  def classify_observation(state, logs) do
    cond do
      error = state["error"] ->
        {:error, "startup error: #{error}"}

      severe = Enum.find(logs, &(&1["level"] == "SEVERE")) ->
        {:error, "severe browser log: #{severe["message"]}"}

      get_in(state, ["surface", "visible"]) == true and
          get_in(state, ["surface", "varied"]) == true ->
        {:ok, :ready}

      true ->
        {:pending, state}
    end
  end

  defp assert_browser_ready!(port, session, integration) do
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
                  "script" => surface_observer(),
                  "args" => []
                }
              )["value"]
              |> Map.put("surface", rendered_surface(port, session))

            logs =
              webdriver_request!(
                :post,
                port,
                "/session/#{session}/se/log",
                %{"type" => "browser"}
              )["value"]

            case classify_observation(state, logs) do
              {:error, reason} -> flunk("#{integration} Web startup failed: #{reason}")
              observation -> observation
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

  defp surface_observer do
    "return {error: window.rekindleError ?? null};"
  end

  defp rendered_surface(port, session) do
    rectangles =
      webdriver_request!(
        :post,
        port,
        "/session/#{session}/execute/sync",
        %{
          "script" => """
          return Array.from(document.querySelectorAll("canvas"))
            .map((canvas) => {
              const bounds = canvas.getBoundingClientRect();
              return {
                x: bounds.left + window.scrollX,
                y: bounds.top + window.scrollY,
                width: bounds.width,
                height: bounds.height
              };
            })
            .filter((bounds) => bounds.width > 0 && bounds.height > 0);
          """,
          "args" => []
        }
      )["value"]

    observations =
      Enum.map(rectangles, fn rectangle ->
        screenshot =
          webdriver_request!(
            :post,
            port,
            "/session/#{session}/goog/cdp/execute",
            %{
              "cmd" => "Page.captureScreenshot",
              "params" => %{
                "format" => "png",
                "fromSurface" => true,
                "clip" => Map.put(rectangle, "scale", 1)
              }
            }
          )
          |> get_in(["value", "data"])

        screenshot
        |> Base.decode64!()
        |> inspect_png()
      end)

    %{
      "present" => rectangles != [],
      "visible" => Enum.any?(observations, & &1.visible),
      "varied" => Enum.any?(observations, &(&1.visible and &1.varied))
    }
  end

  defp inspect_png(<<137, 80, 78, 71, 13, 10, 26, 10, chunks::binary>>) do
    %{header: header, data: data} = png_chunks(chunks, %{header: nil, data: []})
    <<width::32, height::32, 8, color_type, 0, 0, 0>> = header
    channels = png_channels(color_type)
    row_size = width * channels
    inflated = data |> Enum.reverse() |> IO.iodata_to_binary() |> :zlib.uncompress()

    {_rest, _previous, observation} =
      Enum.reduce(1..height, {inflated, List.duplicate(0, row_size), nil}, fn _,
                                                                              {rows, previous,
                                                                               observation} ->
        <<filter, encoded::binary-size(^row_size), rest::binary>> = rows
        row = restore_png_row(encoded, previous, channels, filter)
        {rest, row, inspect_png_row(row, channels, color_type, observation)}
      end)

    observation || %{visible: false, varied: false}
  end

  defp png_chunks(<<0::32, "IEND", _crc::32>>, state), do: state

  defp png_chunks(<<length::32, type::binary-size(4), rest::binary>>, state) do
    <<data::binary-size(^length), _crc::32, remaining::binary>> = rest

    state =
      case type do
        "IHDR" -> %{state | header: data}
        "IDAT" -> %{state | data: [data | state.data]}
        _other -> state
      end

    png_chunks(remaining, state)
  end

  defp png_channels(0), do: 1
  defp png_channels(2), do: 3
  defp png_channels(4), do: 2
  defp png_channels(6), do: 4

  defp restore_png_row(encoded, previous, bytes_per_pixel, filter) do
    previous = :array.from_list(previous)

    restored =
      Enum.reduce(0..(byte_size(encoded) - 1), :array.new(), fn index, output ->
        byte = :binary.at(encoded, index)

        left =
          if index < bytes_per_pixel, do: 0, else: :array.get(index - bytes_per_pixel, output)

        above = :array.get(index, previous)

        upper_left =
          if index < bytes_per_pixel, do: 0, else: :array.get(index - bytes_per_pixel, previous)

        value =
          case filter do
            0 -> byte
            1 -> byte + left
            2 -> byte + above
            3 -> byte + div(left + above, 2)
            4 -> byte + paeth(left, above, upper_left)
          end

        :array.set(index, rem(value, 256), output)
      end)

    :array.to_list(restored)
  end

  defp paeth(left, above, upper_left) do
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)

    cond do
      left_distance <= above_distance and left_distance <= upper_left_distance -> left
      above_distance <= upper_left_distance -> above
      true -> upper_left
    end
  end

  defp inspect_png_row(row, channels, color_type, observation) do
    row
    |> Enum.chunk_every(channels)
    |> Enum.reduce_while(observation, fn pixel, current ->
      sample = png_sample(pixel, color_type)

      next =
        case current do
          nil ->
            %{first: sample, visible: elem(sample, 3) > 0, varied: false}

          value ->
            %{
              value
              | visible: value.visible or elem(sample, 3) > 0,
                varied: value.varied or sample != value.first
            }
        end

      if next.visible and next.varied, do: {:halt, next}, else: {:cont, next}
    end)
  end

  defp png_sample([gray], 0), do: {gray, gray, gray, 255}
  defp png_sample([red, green, blue], 2), do: {red, green, blue, 255}
  defp png_sample([gray, alpha], 4), do: {gray, gray, gray, alpha}
  defp png_sample([red, green, blue, alpha], 6), do: {red, green, blue, alpha}

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
        {:ok, if(response == "", do: %{}, else: Jason.decode!(response))}

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
      <head>
        <meta charset="utf-8">
        <link rel="icon" href="data:,">
        <title>Rekindle startup</title>
      </head>
      <body>
        #{host}
        <script type="module">
          const fail = (error) => {
            const failure = error?.reason ?? error?.error ?? error;
            const message = String(failure?.stack ?? failure);
            if (
              message.includes(
                "Using exceptions for control flow, don't mind me. This isn't actually an error!"
              )
            ) {
              error?.preventDefault?.();
              return;
            }
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
