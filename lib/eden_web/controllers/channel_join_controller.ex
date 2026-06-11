defmodule EdenWeb.ChannelJoinController do
  @moduledoc """
  Joins a channel by invite link (`/channels/join/:token`). Authenticated-only:
  a signed-out visitor is bounced through login (the return path survives via
  `user_return_to`) and lands back here to complete the join.
  """
  use EdenWeb, :controller

  alias Eden.Channels

  def join(conn, %{"token" => token}) do
    case Channels.join_by_token(conn.assigns.current_scope, token) do
      {:ok, channel} ->
        conn
        |> put_flash(:info, gettext("Welcome to %{name}!", name: channel.name))
        |> redirect(to: ~p"/channels/#{channel.id}")

      {:error, reason} ->
        conn
        |> put_flash(:error, join_error(reason))
        |> redirect(to: ~p"/app")
    end
  end

  defp join_error(:expired), do: gettext("This invite link has expired. Ask for a new one.")
  defp join_error(:revoked), do: gettext("This invite link is no longer active.")

  defp join_error(:exhausted),
    do: gettext("This invite link has been used up. Ask for a new one.")

  defp join_error(_invalid), do: gettext("This invite link is invalid.")
end
