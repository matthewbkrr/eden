defmodule EdenWeb.UserSessionController do
  use EdenWeb, :controller

  require Logger

  alias Eden.Accounts
  alias Eden.Accounts.User
  alias EdenWeb.UserAuth

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    case Accounts.get_user_by_username_and_password(username, password) do
      nil ->
        # Logged for auditing brute-force attempts (#236); the throttle already
        # capped the rate. No password is logged, and the username is inspected.
        Logger.warning(
          "Failed login for username=#{inspect(username)} from ip=#{format_ip(conn.remote_ip)}"
        )

        conn
        |> put_flash(:error, gettext("Invalid username or password."))
        |> redirect(to: ~p"/login")

      %User{} = user ->
        # Password is right; if the user has TOTP, don't issue a session yet — stash a
        # short-lived pending marker and hand off to the second-factor challenge (#250).
        if Accounts.totp_enrolled?(user) do
          conn
          |> put_session(:totp_pending_user_id, user.id)
          |> put_session(:totp_pending_at, System.system_time(:second))
          |> redirect(to: ~p"/login/totp")
        else
          conn
          |> put_flash(:info, gettext("Welcome back, %{name}!", name: user.display_name))
          |> UserAuth.log_in_user(user)
        end
    end
  end

  @doc """
  Completes login with the second factor (#250): the same field accepts a TOTP code
  or a one-time backup code. Only reachable with a valid, unexpired pending marker
  from `create/2`; a stolen password never reaches here without the device.
  """
  def totp(conn, %{"totp" => %{"code" => code}}) do
    with id when is_integer(id) <- pending_user_id(conn),
         %User{} = user <- Accounts.get_user(id),
         {:ok, user} <- verify_second_factor(user, code) do
      conn
      |> put_flash(:info, gettext("Welcome back, %{name}!", name: user.display_name))
      |> UserAuth.log_in_user(user)
    else
      _ ->
        conn
        |> put_flash(:error, gettext("That code didn't match. Try again."))
        |> redirect(to: ~p"/login/totp")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("You have been logged out."))
    |> UserAuth.log_out_user()
  end

  # Try the authenticator code first, then fall back to a backup code.
  defp verify_second_factor(user, code) when is_binary(code) do
    case Accounts.verify_totp(user, code) do
      {:ok, user} -> {:ok, user}
      :error -> Accounts.consume_backup_code(user, code)
    end
  end

  defp verify_second_factor(_user, _code), do: :error

  defp pending_user_id(conn) do
    with id when is_integer(id) <- get_session(conn, :totp_pending_user_id),
         at when is_integer(at) <- get_session(conn, :totp_pending_at),
         true <- System.system_time(:second) - at <= UserAuth.totp_pending_ttl_seconds() do
      id
    else
      _ -> nil
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: inspect(ip)
end
