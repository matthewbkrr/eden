defmodule EdenWeb.DeviceController do
  @moduledoc """
  Push-device registration (#418, ADR-0001): the mobile shell POSTs its
  `{kind, token}` here from the already-authenticated WebView — the cookie
  session IS the auth (no bearer layer, by the epic's design), CSRF rides the
  `x-csrf-token` header from the page's meta tag. Re-registration on every app
  start is expected; the context upserts.
  """
  use EdenWeb, :controller

  alias Eden.Notifications

  def register(conn, %{"kind" => kind, "token" => token})
      when is_binary(kind) and is_binary(token) do
    case Notifications.upsert_target(conn.assigns.current_scope, kind, token) do
      {:ok, _target} -> send_resp(conn, 204, "")
      {:error, %Ecto.Changeset{}} -> send_resp(conn, 422, "")
    end
  end

  def register(conn, _params), do: send_resp(conn, 400, "")
end
