defmodule SlintExampleWeb.PageController do
  use SlintExampleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
