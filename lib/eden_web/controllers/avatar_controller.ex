defmodule EdenWeb.AvatarController do
  @moduledoc """
  Serves user avatars to any authenticated user (avatars appear wherever a person
  is shown). The stored blob is always a processed JPEG (see `Accounts.set_avatar/2`),
  so the content-type is server-determined; `nosniff` blocks reinterpretation.
  Callers cache-bust via a `?v=` token, so the immutable cache is keyed per avatar.
  """
  use EdenWeb, :controller

  alias Eden.Accounts
  alias EdenWeb.Avatars

  def show(conn, %{"id" => id}) do
    with {int_id, ""} <- Integer.parse(id),
         %{avatar_key: key} when is_binary(key) <- Accounts.get_user(int_id) do
      Avatars.send_avatar(conn, key)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
