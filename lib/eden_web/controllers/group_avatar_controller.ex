defmodule EdenWeb.GroupAvatarController do
  @moduledoc """
  Serves a group's avatar (#178) to its members — header / sidebar / profile panel
  show it. The stored blob is always a processed JPEG (see `Chat.set_group_avatar/3`),
  so the content-type is server-determined; `nosniff` blocks reinterpretation. A
  non-member (or a group with no avatar) gets 404 — existence isn't leaked across
  conversations. Callers cache-bust via a `?v=` token.
  """
  use EdenWeb, :controller

  alias Eden.Chat
  alias EdenWeb.Avatars

  def show(conn, %{"id" => id}) do
    case Chat.group_avatar_key(conn.assigns.current_scope, id) do
      key when is_binary(key) -> Avatars.send_avatar(conn, key)
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
