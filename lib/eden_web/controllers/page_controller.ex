defmodule EdenWeb.PageController do
  use EdenWeb, :controller

  # The root path is just an entry point, not a landing page: send visitors straight
  # into the messenger — the app when signed in, the login page otherwise.
  def home(conn, _params) do
    if conn.assigns.current_scope do
      redirect(conn, to: ~p"/app")
    else
      redirect(conn, to: ~p"/login")
    end
  end
end
