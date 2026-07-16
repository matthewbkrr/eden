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

  describe "error contract (#373/R158)" do
    test "square_avatar only ever returns the documented atoms, never a raw vix string" do
      # Whatever libvips does on a bad input — raise OR return {:error, "vips string"} — must
      # normalize to :too_large | :unprocessable, never leak a raw binary past the contract.
      inputs = [
        "this is plainly not an image",
        # JPEG magic bytes then garbage: may header-parse yet fail the full decode/encode.
        <<0xFF, 0xD8, 0xFF, 0xE0>> <> "JFIF" <> :binary.copy(<<0>>, 32)
      ]

      for bytes <- inputs do
        path = Path.join(System.tmp_dir!(), "bad-#{System.unique_integer([:positive])}")
        File.write!(path, bytes)
        on_exit(fn -> File.rm(path) end)

        result = Images.square_avatar(path)

        assert result in [{:error, :too_large}, {:error, :unprocessable}],
               "leaked #{inspect(result)}"
      end
    end
  end

  describe "metadata stripping (#373/R210)" do
    # A real fixture that CARRIES EXIF (a stand-in for camera/GPS tags): tag an image and write it
    # WITHOUT stripping. `noisy?` + big dims make compress_photo actually re-encode (not :keep).
    defp exif_jpeg(opts \\ []) do
      {w, h} = Keyword.get(opts, :dims, {600, 400})

      {:ok, base} =
        if opts[:noisy] do
          {:ok, noise} = Vix.Vips.Operation.gaussnoise(w, h)
          Vix.Vips.Operation.cast(noise, :VIPS_FORMAT_UCHAR)
        else
          Image.new(w, h, color: [90, 40, 160])
        end

      {:ok, tagged} =
        Image.mutate(base, fn m ->
          Vix.Vips.MutableImage.set(m, "exif-ifd0-Make", :gchararray, "ihiCam GPS 55.75,37.61")
        end)

      {:ok, bytes} = Image.write(tagged, :memory, suffix: ".jpg", strip_metadata: false)
      path = Path.join(System.tmp_dir!(), "exif-#{System.unique_integer([:positive])}.jpg")
      File.write!(path, bytes)
      on_exit(fn -> File.rm(path) end)
      {path, byte_size(bytes)}
    end

    defp exif_present?(jpeg) do
      {:ok, img} = Image.from_binary(jpeg)
      match?({:ok, %{make: "ihiCam GPS 55.75,37.61"}}, Image.exif(img))
    end

    test "the fixture actually carries EXIF (guard the test itself)" do
      {path, _} = exif_jpeg()
      assert exif_present?(File.read!(path))
    end

    test "square_avatar strips EXIF from its output" do
      {path, _} = exif_jpeg()
      assert {:ok, jpeg} = Images.square_avatar(path)
      refute exif_present?(jpeg)
    end

    test "compress_photo strips EXIF when it re-encodes" do
      # A big noisy image so the long-edge fit + re-encode shrinks it below 90% (→ {:ok, …}).
      {path, size} = exif_jpeg(noisy: true, dims: {3200, 2400})

      case Images.compress_photo(path, size) do
        {:ok, jpeg, _w, _h} -> refute exif_present?(jpeg)
        :keep -> flunk("expected compress_photo to re-encode the big fixture, got :keep")
      end
    end
  end
end
