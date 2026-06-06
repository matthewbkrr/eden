defmodule EdenWeb.PageController do
  use EdenWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
