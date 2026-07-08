defmodule Eden.Images do
  @moduledoc """
  Shared image processing. `square_avatar/1` decodes an uploaded image,
  center-crops it to a square, and re-encodes a metadata-stripped JPEG — used for
  both user avatars (`Accounts`) and channel avatars (`Channels`), so the
  guarantees (size/pixel caps, decompression-bomb guard, EXIF stripped) are
  identical. Bundled libvips (`:image`/vix), no system dependency.
  """
  @avatar_size 512
  @max_bytes 5 * 1024 * 1024
  @max_pixels 100_000_000

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
           ) do
      Image.write(square, :memory, suffix: ".jpg", quality: 82, strip_metadata: true)
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

  defp check_size(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  defp check_size(_bytes), do: {:error, :too_large}

  # Strict `<`: the cap is the first REJECTED value, not the last accepted one (#238).
  defp check_pixels(w, h) when is_integer(w) and is_integer(h) and w * h < @max_pixels, do: :ok
  defp check_pixels(_w, _h), do: {:error, :unprocessable}
end
