defmodule EdenWeb.Avatars do
  @moduledoc """
  Avatar URLs and the response that answers them (#516).

  The stored blob is a 512px JPEG square, and the largest avatar this app renders is
  `.ed-avatar--lg` — 3.5rem, 56 CSS px. Every avatar route used to send that master, so a sidebar
  of 30 people downloaded ~1.2 MB of pixels to paint circles worth ~140 KB. Routes now serve a
  192px WebP variant (56 CSS px at 3x DPR is 168 — one size covers every avatar in the app, which
  is why none of them need `srcset`), derived once by `Eden.Images.variant/2` and cached in
  Storage. Measured on a 3840x2160 photograph: 40.3 KB → 4.8 KB per avatar.

  The `?v=` token hashes the storage key TOGETHER with the width, so changing what we serve
  changes the URL. Without that, an avatar already sitting in a browser's cache under
  `max-age=31536000, immutable` would keep the old master for a year and nobody would see the
  change until they cleared their cache.

  The URL builders live here rather than in each LiveView because they were copied into seven
  places, and a cache-busting rule that has to be remembered in seven places is a rule that will
  drift.
  """
  use EdenWeb, :verified_routes

  import Plug.Conn

  alias Eden.{Images, Storage}

  @doc "Avatar URL for a user, or nil when they have none (the caller renders initials)."
  def user_src(id, key) when is_binary(key), do: ~p"/users/#{id}/avatar?v=#{version(key)}"
  def user_src(_id, _key), do: nil

  @doc "Avatar URL for a group conversation (#178), or nil."
  def group_src(id, key) when is_binary(key),
    do: ~p"/conversations/#{id}/avatar?v=#{version(key)}"

  def group_src(_id, _key), do: nil

  @doc "Avatar URL for a channel (#70), or nil."
  def channel_src(id, key) when is_binary(key), do: ~p"/channels/#{id}/avatar?v=#{version(key)}"
  def channel_src(_id, _key), do: nil

  defp version(key), do: :erlang.phash2({key, Images.avatar_width()})

  @doc """
  Sends the display-sized avatar for an already-authorized storage key.

  A source that cannot be resized (missing, corrupt, or a format libvips declines) falls back to
  the stored blob rather than 404: a broken variant must never cost someone their avatar.
  """
  # The content type is one of two server-chosen literals from `bytes/1` — never anything the
  # client said — and `nosniff` is set alongside, so a polyglot upload can't be reinterpreted.
  # Same false positive, same justification as the thumbnail path in `FileController`.
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  def send_avatar(conn, key) do
    case bytes(key) do
      {:ok, bytes, type, cache} ->
        conn
        |> put_resp_content_type(type, nil)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("cache-control", cache)
        |> send_resp(200, bytes)

      :error ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_status(:not_found)
        |> Phoenix.Controller.text("Not found")
    end
  end

  # The variant is immutable for a year — the URL carries a hash of the key and the width, so
  # those bytes can never mean anything else.
  #
  # The FALLBACK is not. It is served under the same URL, and reaching it means the resize did
  # not work THIS TIME — a storage hiccup, a source libvips choked on. Marking that immutable
  # would pin the 512px master in the browser for a year, long after the variant started
  # working, and nothing would ever ask again (#516 review). `no-store` keeps the avatar showing
  # and lets the next load try for the small one.
  defp bytes(key) do
    case Images.variant(key, Images.avatar_width()) do
      {:ok, small} ->
        {:ok, small, "image/webp", "private, max-age=31536000, immutable"}

      _ ->
        case Storage.read(key) do
          {:ok, whole} -> {:ok, whole, "image/jpeg", "no-store"}
          _ -> :error
        end
    end
  end
end
