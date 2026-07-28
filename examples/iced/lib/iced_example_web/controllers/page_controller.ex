defmodule IcedExampleWeb.PageController do
  use IcedExampleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
