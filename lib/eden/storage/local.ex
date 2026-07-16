defmodule Eden.Storage.Local do
  @moduledoc """
  Local-disk storage adapter (development). Objects live as files under a
  configured `:root` directory. Prod uses an S3-compatible adapter instead,
  selected by config — callers never change.
  """
  @behaviour Eden.Storage

  # File operations here are on app-generated, sanitized keys (see path/1), not on
  # user-supplied paths, so the traversal warnings are false positives.

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def put(key, source_path) do
    dest = path(key)

    with :ok <- File.mkdir_p(Path.dirname(dest)) do
      atomic_write(dest, &File.cp(source_path, &1))
    end
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def put_binary(key, binary) do
    dest = path(key)

    with :ok <- File.mkdir_p(Path.dirname(dest)) do
      atomic_write(dest, &File.write(&1, binary))
    end
  end

  # Write to a sibling temp file, then atomically rename it into place (`File.rename` is atomic on
  # one filesystem), so a crash mid-write can't leave a truncated blob under the FINAL key that
  # `exists?` would report present and serving would hand out (#374/R160). Clean the temp on failure.
  # sobelow_skip ["Traversal.FileModule"]
  defp atomic_write(dest, write_fun) do
    tmp =
      dest <> ".tmp-" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    case write_fun.(tmp) do
      :ok ->
        case File.rename(tmp, dest) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(tmp)
            {:error, reason}
        end

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @impl true
  def local_path(key), do: {:ok, path(key)}

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def read(key), do: File.read(path(key))

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def delete(key) do
    case File.rm(path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(key), do: File.exists?(path(key))

  # Resolve a key under the root, refusing to escape it (defense in depth — keys
  # are app-generated, never user-supplied).
  defp path(key) do
    root = Application.fetch_env!(:eden, __MODULE__)[:root]

    safe =
      key
      |> Path.split()
      |> Enum.reject(&(&1 in ["..", "/", "."]))
      |> Path.join()

    Path.join(root, safe)
  end
end
