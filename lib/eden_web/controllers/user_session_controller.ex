defmodule EdenWeb.UserSessionController do
  use EdenWeb, :controller

  alias Eden.Accounts
  alias EdenWeb.UserAuth

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    case Accounts.get_user_by_username_and_password(username, password) do
      nil ->
        conn
        |> put_flash(:error, gettext("Invalid username or password."))
        |> redirect(to: ~p"/login")

      user ->
        conn
        |> put_flash(:info, gettext("Welcome back, %{name}!", name: user.display_name))
        |> UserAuth.log_in_user(user)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("You have been logged out."))
    |> UserAuth.log_out_user()
  end
end
