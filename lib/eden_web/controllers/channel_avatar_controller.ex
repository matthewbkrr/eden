defmodule EdenWeb.ChannelAvatarController do
  @moduledoc """
  Serves a channel's avatar (#70) to its members — the rail shows it. The stored
  blob is always a processed JPEG (see `Channels.set_channel_avatar/3`), so the
  content-type is server-determined; `nosniff` blocks reinterpretation. A
  non-member (or a channel with no avatar) gets 404 — existence isn't leaked, per
  the Channels authorization model. Callers cache-bust via a `?v=` token.
  """
  use EdenWeb, :controller

  alias Eden.{Channels, Storage}

  # sobelow_skip ["XSS.SendResp"]
  def show(conn, %{"id" => id}) do
    with {:ok, %{avatar_key: key}} when is_binary(key) <-
           Channels.get_channel(conn.assigns.current_scope, id),
         {:ok, bytes} <- Storage.read(key) do
      conn
      |> put_resp_content_type("image/jpeg", nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
