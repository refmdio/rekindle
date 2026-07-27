defmodule EguiExampleWeb.PageControllerTest do
  use EguiExampleWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ ~s(<canvas id="the_canvas_id")
    assert response =~ ~s(src="/rekindle/entry.js")
  end
end
