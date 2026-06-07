defmodule EdenWeb.FileController do
  @moduledoc """
  Serves uploaded attachments. Access is authorized by membership: the bytes are
  only returned if the current user belongs to the attachment's conversation.
  """
  use EdenWeb, :controller

  alias Eden.{Chat, Storage}

  @doc "Serves the original image."
  def show(conn, %{"id" => id}), do: serve(conn, id, :original)

  @doc "Serves the downscaled thumbnail (404 until the worker has produced it)."
  def thumb(conn, %{"id" => id}), do: serve(conn, id, :thumb)

  # The content-type is server-determined by magic-byte detection (see
  # `Chat.create_photo_message/3`) and constrained to a fixed image/* allowlist —
  # never the client-supplied type — and we send `x-content-type-options: nosniff`
  # so the browser cannot reinterpret a polyglot upload as HTML. Both sobelow XSS
  # warnings are false positives under these guarantees.
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  defp serve(conn, id, variant) do
    with {int_id, ""} <- Integer.parse(id),
         {:ok, attachment} <- Chat.fetch_attachment(conn.assigns.current_scope, int_id),
         {:ok, key, content_type} <- variant_source(attachment, variant),
         {:ok, bytes} <- Storage.read(key) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  defp variant_source(attachment, :original),
    do: {:ok, attachment.storage_key, attachment.content_type}

  defp variant_source(%{thumbnail_key: key}, :thumb) when is_binary(key),
    do: {:ok, key, "image/jpeg"}

  defp variant_source(_attachment, :thumb), do: :error
end
