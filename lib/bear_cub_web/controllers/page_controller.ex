defmodule BearCubWeb.PageController do
  use BearCubWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
