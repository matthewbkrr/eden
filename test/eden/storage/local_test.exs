defmodule Eden.Storage.LocalTest do
  use ExUnit.Case, async: true

  alias Eden.Storage.Local

  defp temp_key, do: "test-local/#{System.unique_integer([:positive])}.bin"

  defp no_temp_siblings(path) do
    path
    |> Path.dirname()
    |> File.ls!()
    |> Enum.filter(&String.contains?(&1, ".tmp-"))
  end

  test "put_binary writes atomically — no temp left, blob equals the bytes (#374/R160)" do
    key = temp_key()
    assert :ok = Local.put_binary(key, "hello atomic")

    {:ok, path} = Local.local_path(key)
    on_exit(fn -> File.rm(path) end)

    assert File.read!(path) == "hello atomic"
    assert no_temp_siblings(path) == []
  end

  test "put copies a source file atomically, leaving no temp (#374/R160)" do
    src = Path.join(System.tmp_dir!(), "src-#{System.unique_integer([:positive])}")
    File.write!(src, "sourcebytes")
    on_exit(fn -> File.rm(src) end)

    key = temp_key()
    assert :ok = Local.put(key, src)

    {:ok, path} = Local.local_path(key)
    on_exit(fn -> File.rm(path) end)

    assert File.read!(path) == "sourcebytes"
    assert no_temp_siblings(path) == []
  end
end
