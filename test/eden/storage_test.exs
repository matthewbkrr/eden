defmodule Eden.StorageTest do
  use ExUnit.Case, async: true

  alias Eden.Storage

  defp tmp_source(contents) do
    path = Path.join(System.tmp_dir!(), "src-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "put / read / exists? / delete round-trip" do
    key = Storage.build_key("test", "bin")
    refute Storage.exists?(key)

    assert :ok = Storage.put(key, tmp_source("hello bytes"))
    assert Storage.exists?(key)
    assert {:ok, "hello bytes"} = Storage.read(key)

    assert :ok = Storage.delete(key)
    refute Storage.exists?(key)
    # delete is idempotent
    assert :ok = Storage.delete(key)
  end

  test "put_binary / read round-trip" do
    key = Storage.build_key("thumbnails", "jpg")
    assert :ok = Storage.put_binary(key, <<1, 2, 3, 0, 255>>)
    assert {:ok, <<1, 2, 3, 0, 255>>} = Storage.read(key)
    Storage.delete(key)
  end

  test "build_key/2 is prefixed, has the extension, and is unique" do
    k1 = Storage.build_key("attachments", "png")
    k2 = Storage.build_key("attachments", "png")

    assert String.starts_with?(k1, "attachments/")
    assert String.ends_with?(k1, ".png")
    refute k1 == k2
  end
end
