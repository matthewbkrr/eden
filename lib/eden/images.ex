defmodule Eden.Images do
  @moduledoc """
  Shared image processing. `square_avatar/1` decodes an uploaded image,
  center-crops it to a square, and re-encodes a metadata-stripped JPEG — used for
  both user avatars (`Accounts`) and channel avatars (`Channels`), so the
  guarantees (size/pixel caps, decompression-bomb guard, EXIF stripped) are
  identical. Bundled libvips (`:image`/vix), no system dependency.
  """
  alias Eden.Storage
  alias Vix.Vips.Operation

  @avatar_size 512
  @max_bytes 5 * 1024 * 1024
  # Header pixel cap for the avatar/compress decode paths — checked on the lazy image
  # before any full decode. 40 MP (≈6325²) clears default phone-camera photos (12–24 MP)
  # with headroom while bounding a decompression bomb's memory: over the cap, compress_photo
  # degrades to `:keep` (store the original as-is) and square_avatar rejects. Tighter than
  # the thumbnail-worker cap since these run on the request path (#231).
  @max_pixels 40_000_000

  # Derived display variants (#516). Everything that shows an image shows it SMALLER than it is
  # stored: the largest avatar in the app is 3.5rem (56 CSS px) against a 512px blob, and an album
  # tile three-across is ~105 CSS px against an 800px preview. A sidebar of 30 avatars was
  # downloading ~1.9 MB of pixels to paint ~190 KB worth of circles.
  #
  # 192 covers every avatar (56 CSS px at 3x DPR = 168); 256 covers the small photo surfaces —
  # album tiles, the gallery grid, the lightbox reel, the file card. Wider tiles reach for the
  # 800px preview through `srcset`, so the browser picks per layout and DPR rather than us
  # guessing. Keep this list in step with the callers: `delete_variants/1` sweeps exactly these.
  @avatar_width 192
  @tile_width 256
  @variant_widths [@avatar_width, @tile_width]
  @variant_quality 78

  @doc "Width every avatar route serves (#{@avatar_width}px — covers 3.5rem at 3x DPR)."
  def avatar_width, do: @avatar_width

  @doc "Width the small photo surfaces serve (#{@tile_width}px — album tiles, gallery, reel)."
  def tile_width, do: @tile_width

  # "Golden middle" photo compression (#122), matching the messenger norm (WhatsApp ~1600px/
  # q80, Telegram 1280/q80): fit the long edge to @photo_max and re-encode a metadata-stripped
  # JPEG at @photo_quality. Saves DB/storage on every photo without "shooting" the quality.
  @photo_max 1600
  @photo_quality 82

  @doc """
  Decode → center-crop to a #{@avatar_size}px square → re-encode JPEG with metadata
  stripped. The header is read first to reject decompression bombs; any libvips
  failure (non-image, corrupt) becomes `{:error, :unprocessable}`. `path` is a
  server-assigned upload temp file, not user-supplied.

  Returns `{:ok, jpeg_binary}` | `{:error, :too_large | :unprocessable}`.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def square_avatar(path) do
    with {:ok, bytes} <- File.read(path),
         :ok <- check_size(bytes),
         {:ok, image} <- Image.from_binary(bytes),
         :ok <- check_pixels(Image.width(image), Image.height(image)),
         {:ok, square} <-
           Vix.Vips.Operation.thumbnail_buffer(bytes, @avatar_size,
             height: @avatar_size,
             crop: :VIPS_INTERESTING_CENTRE,
             size: :VIPS_SIZE_BOTH
           ),
         # A `<-` (not the bare do-body) so a RETURNED `{:error, "vips string"}` — a truncated JPEG
         # that header-parses but fails a full decode/encode — is normalized by `else`, not leaked
         # past the documented `:too_large | :unprocessable` contract (#373/R158). Mirrors
         # `heic_to_jpeg` (#123 B1).
         {:ok, jpeg} <-
           Image.write(square, :memory, suffix: ".jpg", quality: 82, strip_metadata: true) do
      {:ok, jpeg}
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :unprocessable}
    end
  rescue
    _ -> {:error, :unprocessable}
  end

  @doc """
  Compress a stored PHOTO for weight (#122): fit the long edge to #{@photo_max}px (only
  downscale, never enlarge) and re-encode a metadata-stripped JPEG at quality #{@photo_quality}.
  Returns `{:ok, jpeg_binary, width, height}` only when the result is meaningfully smaller
  (≤90% of `orig_size`); otherwise `:keep` — so already-small/optimized images and ones that
  wouldn't shrink aren't bloated or needlessly re-encoded. Any libvips failure also yields
  `:keep` (a compression hiccup must never break a send — the original is stored instead).
  `path` is a server-assigned upload temp file.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def compress_photo(path, orig_size) do
    with {:ok, bytes} <- File.read(path),
         {:ok, image} <- Image.from_binary(bytes),
         :ok <- check_pixels(Image.width(image), Image.height(image)),
         {:ok, fitted} <-
           Vix.Vips.Operation.thumbnail_buffer(bytes, @photo_max,
             height: @photo_max,
             size: :VIPS_SIZE_DOWN
           ),
         {:ok, jpeg} <-
           Image.write(fitted, :memory,
             suffix: ".jpg",
             quality: @photo_quality,
             strip_metadata: true
           ) do
      if byte_size(jpeg) <= orig_size * 0.9 do
        {:ok, jpeg, Image.width(fitted), Image.height(fitted)}
      else
        :keep
      end
    else
      _ -> :keep
    end
  rescue
    _ -> :keep
  end

  @doc """
  The storage key a derived variant lives under: `avatars/ab.jpg` at 192 → `avatars/ab@192.webp`.

  Derived from the source key rather than stored in a column so nothing needs a migration and
  blobs that predate a variant pick it up on their next read.
  """
  def variant_key(key, width), do: "#{Path.rootname(key)}@#{width}.webp"

  @doc """
  Bytes of the stored blob `key`, downscaled to fit `width` and encoded as WebP.

  Built on the first request and cached in Storage, so a page full of the same avatar or a
  re-visited album pays for the resize once. A storage that refuses the cache write still serves
  the bytes — the variant is a display optimization, never the reason a request fails.

  Returns `{:error, :unprocessable}` if the source is missing or undecodable; the caller decides
  whether that is a 404 or a fallback to the full-size blob.
  """
  def variant(key, width) do
    vkey = variant_key(key, width)

    case Storage.read(vkey) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> build_variant(key, vkey, width)
    end
  end

  defp build_variant(key, vkey, width) do
    with {:ok, bytes} <- Storage.read(key),
         {:ok, small} <- downscale_webp(bytes, width) do
      cache(key, vkey, small)
      {:ok, small}
    else
      _ -> {:error, :unprocessable}
    end
  end

  # Building a variant reads the source, resizes, then writes — and a delete can land in the
  # middle of that. The delete sweeps the variants that exist at the time, so a write landing
  # after it recreates one whose source is gone: storage nobody will ever look for again
  # (#516 review). Re-checking the source AFTER the write closes all but a vanishing window,
  # and this runs once per variant, on the miss path only.
  #
  # The request is served either way — the bytes are already in hand, and a variant that could
  # not be cached is a slower request, not a failed one.
  defp cache(key, vkey, bytes) do
    Storage.put_binary(vkey, bytes)
    unless Storage.exists?(key), do: Storage.delete(vkey)
    :ok
  end

  @doc """
  Every derived variant of `key`, deleted. Called wherever the source blob is reclaimed, so a
  variant can't outlive what it was derived from.

  Sweeps the whole width list rather than tracking which variants were ever built: deleting a key
  that does not exist is a no-op in every adapter, and a leaked variant is permanent while a
  redundant delete is free. That is also why the callers do not care whether the key they are
  reclaiming ever had a variant.
  """
  def delete_variants(key) when is_binary(key) do
    Enum.each(@variant_widths, &Storage.delete(variant_key(key, &1)))
  end

  def delete_variants(_key), do: :ok

  @doc """
  Reclaims an avatar blob together with its derived variants.

  Every avatar delete path goes through here — replace, remove, channel/group deletion, the
  right-to-erasure scrub, and the rollbacks that reclaim a blob whose row update failed. One
  function so "the variant outlived its source" cannot come back through the eleventh caller.
  """
  def delete_avatar(key) when is_binary(key) do
    Storage.delete(key)
    delete_variants(key)
  end

  def delete_avatar(_key), do: :ok

  @doc """
  Downscale `bytes` to fit `width` and encode WebP with metadata stripped.

  WebP because it is roughly 60% smaller than JPEG at matching quality and has been universal
  since Safari 14 — the stored blob stays JPEG, so nothing existing has to be converted.
  """
  def downscale_webp(bytes, width) do
    with {:ok, image} <- Image.from_binary(bytes),
         :ok <- check_pixels(Image.width(image), Image.height(image)),
         # Shrink-on-load, like every other path here: the full-resolution bitmap is never
         # materialised. The result is a SEQUENTIAL image and can be written exactly once —
         # a second `Image.write` on it fails with "Failed to write VipsImage to buffer", so
         # producing two formats or two sizes means shrinking twice.
         {:ok, thumb} <- Operation.thumbnail_buffer(bytes, width, size: :VIPS_SIZE_DOWN),
         {:ok, webp} <-
           Image.write(thumb, :memory,
             suffix: ".webp",
             quality: @variant_quality,
             strip_metadata: true
           ) do
      {:ok, webp}
    else
      _ -> {:error, :unprocessable}
    end
  rescue
    _ -> {:error, :unprocessable}
  end

  defp check_size(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  defp check_size(_bytes), do: {:error, :too_large}

  # Strict `<`: the cap is the first REJECTED value, not the last accepted one (#238).
  defp check_pixels(w, h) when is_integer(w) and is_integer(h) and w * h < @max_pixels, do: :ok
  defp check_pixels(_w, _h), do: {:error, :unprocessable}
end
