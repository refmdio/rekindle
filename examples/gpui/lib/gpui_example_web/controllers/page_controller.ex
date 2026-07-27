defmodule GpuiExampleWeb.PageController do
  use GpuiExampleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
