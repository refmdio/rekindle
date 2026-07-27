defmodule EguiExampleWeb.PageController do
  use EguiExampleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
