defmodule EdenWeb.FileController do
  @moduledoc """
  Serves uploaded attachments. Access is authorized by membership: the bytes are
  only returned if the current user belongs to the attachment's conversation.

  Media (images, video, audio) is served `inline`; generic files are served as a
  download (`attachment` with the sanitized original name). Range requests are
  honored (206 partial content), which is what lets `<video>` seek.
  """
  use EdenWeb, :controller

  alias Eden.{Chat, Storage}

  @doc "Serves the original file (honoring Range requests)."
  def show(conn, %{"id" => id}), do: serve(conn, id, :original)

  @doc "Serves the downscaled image thumbnail / video poster (404 until the worker produces it)."
  def thumb(conn, %{"id" => id}), do: serve(conn, id, :thumb)

  defp serve(conn, id, variant) do
    with {int_id, ""} <- Integer.parse(id),
         {:ok, attachment} <- Chat.fetch_attachment(conn.assigns.current_scope, int_id),
         {:ok, key, content_type, disposition} <- variant_source(attachment, variant) do
      deliver(conn, key, content_type, disposition)
    else
      _ -> not_found(conn)
    end
  end

  # The content-type is server-determined (magic-byte classification in
  # `Chat.create_attachment_message/3`, or a fixed value for thumbnails), never
  # the client-supplied type, and we send `x-content-type-options: nosniff` so the
  # browser cannot reinterpret a polyglot upload as HTML — generic files are
  # additionally forced to download. The sobelow XSS warnings are false positives
  # under those guarantees. `nil` charset keeps the type clean (`video/mp4`).
  # sobelow_skip ["XSS.ContentType"]
  defp deliver(conn, key, content_type, disposition) do
    if Storage.exists?(key) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", disposition)
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("accept-ranges", "bytes")
      |> send_object(key)
    else
      not_found(conn)
    end
  end

  # Stream from disk (sendfile, no full-file copy into memory) when the adapter is
  # disk-backed; fall back to reading bytes for a remote adapter. The path comes
  # from `Storage.local_path/1` over an app-generated, sanitized key.
  defp send_object(conn, key) do
    case Storage.local_path(key) do
      {:ok, path} -> send_local(conn, path)
      :error -> send_remote(conn, key)
    end
  end

  # The path is from `Storage.local_path/1` over an app-generated, sanitized key
  # (never user input), so the send_file traversal warnings are false positives.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_local(conn, path) do
    %{size: total} = File.stat!(path)

    case parse_range(get_req_header(conn, "range"), total) do
      {:ok, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn |> put_resp_header("content-range", "bytes */#{total}") |> send_resp(416, "")

      :none ->
        send_file(conn, 200, path)
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp send_remote(conn, key) do
    case Storage.read(key) do
      {:ok, bytes} -> send_remote_bytes(conn, bytes)
      {:error, _} -> not_found(conn)
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp send_remote_bytes(conn, bytes) do
    total = byte_size(bytes)

    case parse_range(get_req_header(conn, "range"), total) do
      {:ok, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
        |> send_resp(206, binary_part(bytes, first, last - first + 1))

      :unsatisfiable ->
        conn |> put_resp_header("content-range", "bytes */#{total}") |> send_resp(416, "")

      :none ->
        send_resp(conn, 200, bytes)
    end
  end

  # Single-range `bytes=` requests only; anything else (multi-range, malformed,
  # or no header) serves the whole object with 200. Returns inclusive byte bounds.
  defp parse_range([], _total), do: :none

  defp parse_range([value | _], total) do
    case Regex.run(~r/^bytes=(\d*)-(\d*)$/, value) do
      [_, first, last] -> resolve_range(first, last, total)
      _ -> :none
    end
  end

  defp resolve_range("", "", _total), do: :none

  # Suffix range: the last N bytes.
  defp resolve_range("", last, total) do
    n = String.to_integer(last)
    if n > 0, do: clamp(max(total - n, 0), total - 1, total), else: :unsatisfiable
  end

  defp resolve_range(first, "", total), do: clamp(String.to_integer(first), total - 1, total)

  defp resolve_range(first, last, total),
    do: clamp(String.to_integer(first), min(String.to_integer(last), total - 1), total)

  defp clamp(first, last, total) when first <= last and first >= 0 and last < total,
    do: {:ok, first, last}

  defp clamp(_first, _last, _total), do: :unsatisfiable

  # Drop any cache header set on the success path so a 404 (e.g. a blob missing
  # out-of-band) is never cached as immutable for a year.
  defp not_found(conn) do
    conn
    |> delete_resp_header("cache-control")
    |> put_status(:not_found)
    |> text("Not found")
  end

  defp variant_source(attachment, :original),
    do: {:ok, attachment.storage_key, attachment.content_type, disposition(attachment)}

  defp variant_source(%{thumbnail_key: key}, :thumb) when is_binary(key),
    do: {:ok, key, "image/jpeg", "inline"}

  defp variant_source(_attachment, :thumb), do: :error

  # Generic files download with their original name; media renders inline.
  defp disposition(%{kind: "file", filename: name}) when is_binary(name) do
    fallback = String.replace(name, ~r/[^\x20-\x7e]/, "_")
    encoded = URI.encode(name, &URI.char_unreserved?/1)
    ~s(attachment; filename="#{fallback}"; filename*=UTF-8''#{encoded})
  end

  defp disposition(%{kind: "file"}), do: "attachment"
  defp disposition(_attachment), do: "inline"
end
