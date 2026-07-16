defmodule Rekindle.Phoenix.ComponentsTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Rekindle.Phoenix.Components

  @otp_app :rekindle_component_test
  @endpoint __MODULE__.Endpoint

  defmodule Endpoint do
    def static_path("/rekindle/entry.js"), do: "/rekindle/entry-ABC123.js"
  end

  setup do
    previous_endpoint = Application.get_env(@otp_app, @endpoint)
    previous_dev = Application.get_env(@otp_app, :rekindle_dev)
    previous_runtime = Application.get_env(@otp_app, :rekindle_page_runtime)

    on_exit(fn ->
      restore_env(@endpoint, previous_endpoint)
      restore_env(:rekindle_dev, previous_dev)
      restore_env(:rekindle_page_runtime, previous_runtime)
    end)

    :ok
  end

  test "renders exactly one session-scoped external development marker" do
    Application.put_env(@otp_app, @endpoint, code_reloader: true)
    Application.put_env(@otp_app, :rekindle_dev, enabled: true)

    Application.put_env(@otp_app, :rekindle_page_runtime,
      socket_path: "/socket/rekindle",
      project_session: "0123456789abcdef0123456789abcdef",
      token: "token-<&>-0123456789012345678901234"
    )

    html = render_component(&Components.gpui_page/1, otp_app: @otp_app, endpoint: @endpoint)

    assert count(html, ~s(data-rekindle-page="v1")) == 1
    assert count(html, "<script") == 1
    assert html =~ ~s(type="module")
    assert html =~ ~s(src="/_rekindle/runtime.js?session=0123456789abcdef0123456789abcdef")
    assert html =~ ~s(data-rekindle-socket="/socket/rekindle")
    assert html =~ ~s(data-rekindle-project-session="0123456789abcdef0123456789abcdef")
    assert html =~ ~s(data-rekindle-token="token-&lt;&amp;&gt;-0123456789012345678901234")
    refute html =~ "<div"
    refute html =~ "eval("
  end

  test "renders a token-free production static path" do
    Application.put_env(@otp_app, @endpoint, code_reloader: false)
    Application.put_env(@otp_app, :rekindle_dev, enabled: false)

    html = render_component(&Components.gpui_page/1, otp_app: @otp_app, endpoint: @endpoint)

    assert count(html, "<script") == 1
    assert html =~ ~s(src="/rekindle/entry-ABC123.js")
    assert html =~ ~s(data-rekindle-page="v1")
    refute html =~ "token"
    refute html =~ "socket"
    refute html =~ "project-session"
    refute html =~ "runtime.js"
    refute html =~ "<div"
  end

  test "development rendering requires an active bounded session" do
    Application.put_env(@otp_app, @endpoint, code_reloader: true)
    Application.put_env(@otp_app, :rekindle_dev, enabled: true)

    assert_raise ArgumentError, fn ->
      render_component(&Components.gpui_page/1, otp_app: @otp_app, endpoint: @endpoint)
    end
  end

  test "development rendering rejects noncanonical or cross-origin socket paths" do
    Application.put_env(@otp_app, @endpoint, code_reloader: true)
    Application.put_env(@otp_app, :rekindle_dev, enabled: true)

    for socket_path <- [
          "//evil.example/socket",
          "https://evil.example/socket",
          "socket/rekindle",
          "/socket//rekindle",
          "/socket/./rekindle",
          "/socket/../rekindle",
          "/socket\\rekindle",
          "/socket?authority=evil.example",
          "/socket#fragment",
          "/socket%2Fescape",
          "/socket\0escape",
          "/"
        ] do
      Application.put_env(@otp_app, :rekindle_page_runtime,
        socket_path: socket_path,
        project_session: "0123456789abcdef0123456789abcdef",
        token: String.duplicate("t", 32)
      )

      assert_raise ArgumentError, fn ->
        render_component(&Components.gpui_page/1, otp_app: @otp_app, endpoint: @endpoint)
      end
    end
  end

  test "exports only one page marker function" do
    functions = Components.__info__(:functions)
    assert {:gpui_page, 1} in functions
    refute Enum.any?(functions, fn {name, _arity} -> name in [:mount, :host, :gpui_mount] end)
  end

  test "compile fixtures enforce the exact remote component contract" do
    assert {:ok, modules} = compile_fixture("positive.fixture")
    assert modules != []

    cases = [
      {"missing_otp_app.fixture", ~s(missing required attribute "otp_app")},
      {"missing_endpoint.fixture", ~s(missing required attribute "endpoint")},
      {"wrong_otp_app_type.fixture", ~s(attribute "otp_app")},
      {"wrong_endpoint_type.fixture", ~s(attribute "endpoint")},
      {"extra_attr.fixture", ~s(undefined attribute "extra")},
      {"block_invocation.fixture", ~s(undefined slot "inner_block")},
      {"local_invocation.fixture", "undefined function gpui_page/1"}
    ]

    for {fixture, expected} <- cases do
      assert {:error, diagnostics} = compile_fixture(fixture)
      assert Enum.any?(diagnostics, &String.contains?(&1.message, expected))
    end
  end

  defp count(value, pattern), do: value |> String.split(pattern) |> length() |> Kernel.-(1)

  defp compile_fixture(name) do
    path = Path.expand("../../fixtures/phoenix_components/#{name}", __DIR__)

    {{result, diagnostics}, _captured} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Code.with_diagnostics(
          [log: false],
          fn ->
            try do
              {:ok, Code.compile_file(path)}
            rescue
              error -> {:error, error}
            end
          end
        )
      end)

    case {result, diagnostics} do
      {{:ok, modules}, []} -> {:ok, modules}
      {_result, diagnostics} when diagnostics != [] -> {:error, diagnostics}
      {{:error, error}, []} -> {:error, [%{message: Exception.message(error)}]}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(@otp_app, key)
  defp restore_env(key, value), do: Application.put_env(@otp_app, key, value)
end
