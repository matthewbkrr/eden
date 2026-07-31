defmodule Eden.ImagesVariantRaceTest do
  # Building a variant is read → resize → write, and a delete can land in the middle. The delete
  # sweeps the variants that exist when it runs, so a write landing after it recreates one whose
  # source is gone — storage nobody will ever look for again, because the only thing that names a
  # variant is its source (#516 review).
  #
  # The interleaving is not reachable from a test against the real adapter, so this drives it
  # through the storage seam: an adapter that deletes the source AS the builder reads it puts the
  # delete exactly where the race puts it. `async: false` — swapping the adapter is global.
  use ExUnit.Case, async: false

  alias Eden.Images

  defmodule VanishingSource do
    @moduledoc false
    @behaviour Eden.Storage

    def start(bytes) do
      Application.put_env(:eden, __MODULE__, %{"src.jpg" => bytes})
    end

    def contents, do: Application.get_env(:eden, __MODULE__, %{})
    defp put_map(map), do: Application.put_env(:eden, __MODULE__, map)

    @impl true
    def read(key) do
      case Map.fetch(contents(), key) do
        {:ok, bytes} ->
          # The source is deleted the moment it has been handed over — the builder is holding
          # bytes for a key that no longer exists, which is precisely the race.
          put_map(Map.delete(contents(), key))
          {:ok, bytes}

        :error ->
          {:error, :enoent}
      end
    end

    @impl true
    def exists?(key), do: Map.has_key?(contents(), key)

    @impl true
    def put_binary(key, bytes) do
      put_map(Map.put(contents(), key, bytes))
      :ok
    end

    @impl true
    def put(_key, _path), do: :ok

    @impl true
    def delete(key) do
      put_map(Map.delete(contents(), key))
      :ok
    end
  end

  setup do
    prev = Application.get_env(:eden, Eden.Storage)
    Application.put_env(:eden, Eden.Storage, adapter: VanishingSource)
    on_exit(fn -> Application.put_env(:eden, Eden.Storage, prev) end)
    :ok
  end

  test "a variant is not left behind when its source is deleted mid-build" do
    alias Vix.Vips.Operation, as: Op
    {:ok, noise} = Op.perlin(600, 600, cell_size: 64)
    {:ok, cast} = Op.cast(noise, :VIPS_FORMAT_UCHAR)
    {:ok, rgb} = Op.bandjoin([cast, cast, cast])
    {:ok, image} = Op.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
    {:ok, jpeg} = Image.write(image, :memory, suffix: ".jpg", quality: 80)

    VanishingSource.start(jpeg)

    # The request itself still succeeds: the bytes are in hand, and a variant that could not be
    # kept is a slower request, not a failed one.
    assert {:ok, small} = Images.variant("src.jpg", Images.tile_width())
    assert byte_size(small) > 0

    refute Map.has_key?(
             VanishingSource.contents(),
             Images.variant_key("src.jpg", Images.tile_width())
           ),
           "the variant outlived the source it was derived from"
  end
end
