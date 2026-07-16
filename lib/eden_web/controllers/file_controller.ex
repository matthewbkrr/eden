defmodule EdenWeb.FileController do
  @moduledoc """
  Serves uploaded attachments. Access is authorized by membership: the bytes are
  only returned if the current user belongs to the attachment's conversation.

  Media (images, video) is served `inline` (carrying the original name so "Save as…"
  is meaningful); generic files are served as a download (`attachment` with the
  sanitized original name). Range requests are honored (206 partial content), which
  is what lets `<video>` seek — resolved against the DB `byte_size` so a remote
  adapter pulls only the requested window, not the whole object.
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
         {:ok, key, content_type, disposition, total} <- variant_source(attachment, variant) do
      deliver(conn, key, content_type, disposition, total)
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
  # No `Storage.exists?` pre-check (#374/R045): it was a wasted signed HEAD before every remote
  # GET, and the disk path re-stats anyway. A blob that vanished out-of-band surfaces as a 404
  # from `send_local` (File.stat) / `send_remote` (read error); `error_resp` then scrubs the
  # headers set here so the 404 isn't cached immutable or served as an attachment (#374/R167/R170).
  # sobelow_skip ["XSS.ContentType"]
  defp deliver(conn, key, content_type, disposition, total) do
    conn
    |> put_resp_content_type(content_type, nil)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-disposition", disposition)
    |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
    |> put_resp_header("accept-ranges", "bytes")
    |> send_object(key, total)
  end

  # Stream from disk (sendfile, no full-file copy into memory) when the adapter is
  # disk-backed; fall back to a ranged read for a remote adapter. The path comes
  # from `Storage.local_path/1` over an app-generated, sanitized key. `total` is the
  # object's known size (the DB `byte_size` for an original; nil for a thumbnail).
  defp send_object(conn, key, total) do
    case Storage.local_path(key) do
      {:ok, path} -> send_local(conn, path)
      :error -> send_remote(conn, key, total)
    end
  end

  # The path is from `Storage.local_path/1` over an app-generated, sanitized key
  # (never user input), so the send_file traversal warnings are false positives.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_local(conn, path) do
    # Re-stat rather than trust the earlier exists? check: the blob can vanish
    # between the two, and a missing file is a 404, not a 500.
    case File.stat(path) do
      {:ok, %{size: total}} -> send_local(conn, path, total)
      {:error, _reason} -> not_found(conn)
    end
  end

  # sobelow_skip ["Traversal.SendFile"]
  defp send_local(conn, path, total) do
    case parse_range(get_req_header(conn, "range"), total) do
      {:ok, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn |> put_resp_header("content-range", "bytes */#{total}") |> error_resp(416)

      :none ->
        send_file(conn, 200, path)
    end
  end

  # A thumbnail (no stored size, and never seeked) → read it whole.
  # sobelow_skip ["XSS.SendResp"]
  defp send_remote(conn, key, nil) do
    case Storage.read(key) do
      {:ok, bytes} -> send_resp(conn, 200, bytes)
      {:error, _} -> not_found(conn)
    end
  end

  # An original with a known size: resolve the Range against the DB `byte_size` (no HEAD, no full
  # read), then pull ONLY that window via `read_range` (a single ranged GET for S3) (#374/R045).
  # sobelow_skip ["XSS.SendResp"]
  defp send_remote(conn, key, total) do
    case parse_range(get_req_header(conn, "range"), total) do
      {:ok, first, last} ->
        case Storage.read_range(key, {first, last}) do
          {:ok, bytes} ->
            conn
            |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
            |> send_resp(206, bytes)

          {:error, _} ->
            not_found(conn)
        end

      :unsatisfiable ->
        conn |> put_resp_header("content-range", "bytes */#{total}") |> error_resp(416)

      :none ->
        case Storage.read(key) do
          {:ok, bytes} -> send_resp(conn, 200, bytes)
          {:error, _} -> not_found(conn)
        end
    end
  end

  # Single-range `bytes=` requests only; anything else (multi-range, malformed,
  # or no header) serves the whole object with 200. Returns inclusive byte bounds.
  defp parse_range([], _total), do: :none

  defp parse_range([value | _], total) do
    # `bytes` is a case-INsensitive range-unit per RFC 9110 (`Bytes=0-99` is valid), so match `/i`
    # rather than serve a non-standard client the whole 50 MB object with a 200 (#374/R169).
    case Regex.run(~r/^bytes=(\d*)-(\d*)$/i, value) do
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

  defp not_found(conn), do: error_resp(conn, 404, "Not found")

  # Every error response (404, 416) must shed the success-path headers set in `deliver` so it's
  # never cached immutable for a year (#374/R167) and a browser can't download it under the
  # original name/type (#374/R170) — Phoenix's `text/2` would NOT override an already-set
  # content-type, so force text/plain explicitly. A 416 keeps its `content-range` (set by the
  # caller); we don't delete that.
  # sobelow_skip ["XSS.SendResp"]
  defp error_resp(conn, status, body \\ "") do
    conn
    |> delete_resp_header("cache-control")
    |> delete_resp_header("content-disposition")
    |> delete_resp_header("accept-ranges")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  defp variant_source(attachment, :original),
    do:
      {:ok, attachment.storage_key, attachment.content_type, disposition(attachment),
       attachment.byte_size}

  # A thumbnail has no stored size — nil signals "read whole" on the remote path.
  defp variant_source(%{thumbnail_key: key}, :thumb) when is_binary(key),
    do: {:ok, key, "image/jpeg", "inline", nil}

  defp variant_source(_attachment, :thumb), do: :error

  # Generic files download with their original name; media renders inline — but inline media still
  # carries its name so "Save as…" doesn't default to the URL id (#374/R171).
  defp disposition(%{kind: "file", filename: name}) when is_binary(name),
    do: "attachment; " <> name_params(name)

  defp disposition(%{kind: "file"}), do: "attachment"

  defp disposition(%{filename: name}) when is_binary(name),
    do: "inline; " <> name_params(name)

  defp disposition(_attachment), do: "inline"

  # `filename="<ascii>"; filename*=UTF-8''<encoded>` (#238). The ASCII fallback strips the
  # quoted-string metacharacters `"` `\` `;` — a `"` would otherwise close `filename="…"` early and
  # let the rest be read as extra header params. CRLF is already impossible (control chars fall
  # outside \x20-\x7e). Modern browsers use the accurate `filename*`.
  defp name_params(name) do
    fallback = String.replace(name, ~r/[^\x20-\x7e]|["\\;]/, "_")
    encoded = URI.encode(name, &URI.char_unreserved?/1)
    ~s(filename="#{fallback}"; filename*=UTF-8''#{encoded})
  end
end
