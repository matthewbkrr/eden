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

  defp check_size(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  defp check_size(_bytes), do: {:error, :too_large}

  defp check_pixels(w, h) when is_integer(w) and is_integer(h) and w * h <= @max_pixels, do: :ok
  defp check_pixels(_w, _h), do: {:error, :unprocessable}
end
