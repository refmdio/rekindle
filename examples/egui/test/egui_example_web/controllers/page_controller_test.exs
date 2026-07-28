defmodule EguiExampleWeb.PageControllerTest do
  use EguiExampleWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ ~s(src="/rekindle/entry.js")
    assert response =~ ~s(<canvas id="the_canvas_id"></canvas>)
  end
end
