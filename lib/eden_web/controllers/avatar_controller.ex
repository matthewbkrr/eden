defmodule EdenWeb.AvatarController do
  @moduledoc """
  Serves user avatars to any authenticated user (avatars appear wherever a person
  is shown). The stored blob is always a processed JPEG (see `Accounts.set_avatar/2`),
  so the content-type is server-determined; `nosniff` blocks reinterpretation.
  Callers cache-bust via a `?v=` token, so the immutable cache is keyed per avatar.
  """
  use EdenWeb, :controller

  alias Eden.{Accounts, Storage}

  # sobelow_skip ["XSS.SendResp"]
  def show(conn, %{"id" => id}) do
    with {int_id, ""} <- Integer.parse(id),
         %{avatar_key: key} when is_binary(key) <- Accounts.get_user(int_id),
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
