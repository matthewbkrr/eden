defmodule Eden.ImagesTest do
  use ExUnit.Case, async: true

  alias Eden.Images

  # A solid-colour image of the given dimensions, PNG-encoded to a temp file. Solid
  # colour compresses tiny, so an oversized *header* stays a small file — exactly the
  # decompression-bomb shape the pixel cap defends against (#231).
  defp image_file(w, h) do
    {:ok, img} = Image.new(w, h, color: [40, 90, 200])
    {:ok, bytes} = Image.write(img, :memory, suffix: ".png")
    path = Path.join(System.tmp_dir!(), "img-#{System.unique_integer([:positive])}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    {path, byte_size(bytes)}
  end

  describe "pixel cap (#231)" do
    test "square_avatar rejects an image whose header exceeds the 40 MP cap" do
      # 7000×7000 = 49 MP, over the cap, but a few-KB solid PNG — the guard must fire
      # on the header before any full decode.
      {path, _size} = image_file(7000, 7000)
      assert {:error, :unprocessable} = Images.square_avatar(path)
    end

    test "compress_photo degrades to :keep for an over-cap image (stores the original)" do
      {path, size} = image_file(7000, 7000)
      assert :keep = Images.compress_photo(path, size)
    end

    test "a normal image still processes" do
      {path, size} = image_file(600, 400)
      assert {:ok, jpeg} = Images.square_avatar(path)
      assert is_binary(jpeg)
      # compress_photo returns {:ok, …} or :keep depending on how much it shrinks —
      # both are success (never an error) for an in-cap image. Bind once (don't re-run
      # the encode inside the assertion).
      compressed = Images.compress_photo(path, size)
      assert compressed == :keep or match?({:ok, _, _, _}, compressed)
    end
  end
end
