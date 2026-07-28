defmodule GpuiExampleWeb.PageControllerTest do
  use GpuiExampleWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ ~s(src="/rekindle/entry.js")
    assert response =~ ~s(data-rust-ui="gpui")
  end
end
