defmodule EdenWeb.ChannelAvatarController do
  @moduledoc """
  Serves a channel's avatar (#70) to its members — the rail shows it. The stored
  blob is always a processed JPEG (see `Channels.set_channel_avatar/3`), so the
  content-type is server-determined; `nosniff` blocks reinterpretation. A
  non-member (or a channel with no avatar) gets 404 — existence isn't leaked, per
  the Channels authorization model. Callers cache-bust via a `?v=` token.
  """
  use EdenWeb, :controller

  alias Eden.Channels
  alias EdenWeb.Avatars

  def show(conn, %{"id" => id}) do
    case Channels.get_channel(conn.assigns.current_scope, id) do
      {:ok, %{avatar_key: key}} when is_binary(key) -> Avatars.send_avatar(conn, key)
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
