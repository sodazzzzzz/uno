defmodule UnoWeb.PageController do
  use UnoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
