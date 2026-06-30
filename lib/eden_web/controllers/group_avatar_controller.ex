defmodule EdenWeb.GroupAvatarController do
  @moduledoc """
  Serves a group's avatar (#178) to its members — header / sidebar / profile panel
  show it. The stored blob is always a processed JPEG (see `Chat.set_group_avatar/3`),
  so the content-type is server-determined; `nosniff` blocks reinterpretation. A
  non-member (or a group with no avatar) gets 404 — existence isn't leaked across
  conversations. Callers cache-bust via a `?v=` token.
  """
  use EdenWeb, :controller

  alias Eden.{Chat, Storage}

  # sobelow_skip ["XSS.SendResp"]
  def show(conn, %{"id" => id}) do
    with key when is_binary(key) <- Chat.group_avatar_key(conn.assigns.current_scope, id),
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
