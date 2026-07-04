defmodule EdenWeb.UserAuth do
  @moduledoc """
  Authentication plumbing: session login/logout, the `current_scope` plug, and
  `on_mount` hooks for LiveView (Phoenix 1.8 scope pattern). No email — sessions
  are established by accepting an invite or signing in with username + password.
  """
  use EdenWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Eden.Accounts
  alias Eden.Accounts.Scope

  @session_key "user_token"

  # How long a password-verified pending-2FA marker stays valid before the
  # second-factor challenge (#250) expires and sends the user back to /login. Single
  # source of truth for both the controller (which sets it) and TotpLive (which reads it).
  @totp_pending_ttl_seconds 300

  @doc "Seconds a pending-2FA (post-password) marker stays valid (#250)."
  def totp_pending_ttl_seconds, do: @totp_pending_ttl_seconds

  @doc """
  Logs the user in: issues a session token, renews the session to prevent
  fixation, and redirects to the stored return path or the signed-in home.
  """
  def log_in_user(conn, user, _params \\ %{}) do
    token = Accounts.generate_user_session_token(user)
    # Captured before renew_session/1 wipes the session.
    return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> redirect(to: return_to || signed_in_path(conn))
  end

  @doc "Logs the user out, revoking the session token and live sessions."
  def log_out_user(conn) do
    token = get_session(conn, @session_key)
    token && Accounts.delete_user_session_token(token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      EdenWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  @doc "Plug: assigns `:current_scope` from the session token (or nil)."
  def fetch_current_scope_for_user(conn, _opts) do
    user =
      case get_session(conn, @session_key) do
        token when is_binary(token) -> Accounts.get_user_by_session_token(token)
        _ -> nil
      end

    assign(conn, :current_scope, Scope.for_user(user))
  end

  @doc """
  Plug: requires an authenticated user (for protected controller routes), else
  redirects to /login — remembering where a GET was headed (e.g. a channel
  invite link), so login lands back there.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :user_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  @doc "Plug: bounces already-authenticated users away from auth pages."
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns.current_scope do
      conn |> redirect(to: signed_in_path(conn)) |> halt()
    else
      conn
    end
  end

  ## LiveView on_mount

  @doc """
  on_mount hooks:
    * `:mount_current_scope` - assigns `current_scope` (may be nil)
    * `:require_authenticated` - assigns it and halts to /login if absent
    * `:require_admin` - like `:require_authenticated`, plus halts non-admins to the app (#174)
    * `:redirect_if_authenticated` - sends signed-in users to the home page
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/login")

      {:halt, socket}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    cond do
      is_nil(user) ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
         |> Phoenix.LiveView.redirect(to: ~p"/login")}

      not Accounts.admin?(user) ->
        # Authenticated but not an admin — bounce to the app without confirming the
        # admin panel even exists.
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You don't have access to that page.")
         |> Phoenix.LiveView.redirect(to: signed_in_path(socket))}

      not Accounts.totp_enrolled?(user) ->
        # An admin's second factor is mandatory (#250, ADR-0002 Decision 7): they can
        # hold a reset link for anyone, so hijacking an admin = hijacking everyone.
        # Send them to Settings to enroll before any admin power is reachable.
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(
           :error,
           "Turn on two-factor authentication to use the admin panel."
         )
         |> Phoenix.LiveView.redirect(to: ~p"/settings")}

      true ->
        {:cont, socket}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_scope, fn ->
        user =
          case session[@session_key] do
            token when is_binary(token) -> Accounts.get_user_by_session_token(token)
            _ -> nil
          end

        Scope.for_user(user)
      end)

    maybe_watch_sessions(socket)
  end

  # #256: on the CONNECTED mount, subscribe every authenticated LiveView to its
  # user's session-revocation signal and attach a handle_info hook. So when
  # `revoke_all_user_sessions/1` fires (password change / reset / "log out
  # everywhere"), the already-open socket is booted to sign-in immediately instead
  # of surviving until the next reconnect. Runs here — the shared base of every
  # on_mount hook — so it covers ChatLive, AdminLive, and SettingsLive alike.
  defp maybe_watch_sessions(socket) do
    scope = socket.assigns.current_scope

    if (Phoenix.LiveView.connected?(socket) and scope) && scope.user do
      Accounts.subscribe_user_sessions(scope)

      Phoenix.LiveView.attach_hook(
        socket,
        :sessions_revoked,
        :handle_info,
        &on_sessions_revoked/2
      )
    else
      socket
    end
  end

  defp on_sessions_revoked(:sessions_revoked, socket) do
    {:halt,
     socket
     |> Phoenix.LiveView.put_flash(:error, "Your session ended. Please sign in again.")
     |> Phoenix.LiveView.redirect(to: ~p"/login")}
  end

  defp on_sessions_revoked(_message, socket), do: {:cont, socket}

  ## Internals

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(@session_key, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp signed_in_path(_conn_or_socket), do: ~p"/app"
end
