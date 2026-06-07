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
  # so the browser cannot reinterpret a polyglot upload as HTML. The sobelow
  # warning is a false positive under those guarantees. `nil` charset keeps the
  # response type clean (`image/png`, not `image/png; charset=utf-8`).
  # sobelow_skip ["XSS.ContentType"]
  defp serve(conn, id, variant) do
    with {int_id, ""} <- Integer.parse(id),
         {:ok, attachment} <- Chat.fetch_attachment(conn.assigns.current_scope, int_id),
         {:ok, key, content_type} <- variant_source(attachment, variant) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_object(key)
    else
      _ -> not_found(conn)
    end
  end

  # Stream from disk (sendfile, no full-file copy into memory) when the adapter is
  # disk-backed; fall back to reading bytes for a remote adapter. The path comes
  # from `Storage.local_path/1` over an app-generated, sanitized key.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_object(conn, key) do
    if Storage.exists?(key) do
      case Storage.local_path(key) do
        {:ok, path} -> send_file(conn, 200, path)
        :error -> read_and_send(conn, key)
      end
    else
      not_found(conn)
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp read_and_send(conn, key) do
    case Storage.read(key) do
      {:ok, bytes} -> send_resp(conn, 200, bytes)
      {:error, _} -> not_found(conn)
    end
  end

  # Drop any cache header set on the success path so a 404 (e.g. a blob missing
  # out-of-band) is never cached as immutable for a year.
  defp not_found(conn) do
    conn
    |> delete_resp_header("cache-control")
    |> put_status(:not_found)
    |> text("Not found")
  end

  defp variant_source(attachment, :original),
    do: {:ok, attachment.storage_key, attachment.content_type}

  defp variant_source(%{thumbnail_key: key}, :thumb) when is_binary(key),
    do: {:ok, key, "image/jpeg"}

  defp variant_source(_attachment, :thumb), do: :error
end
