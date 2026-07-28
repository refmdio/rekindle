defmodule SlintExampleWeb.PageControllerTest do
  use SlintExampleWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ ~s(data-rust-ui="slint")
  end
end
