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
    File.mkdir_p!(Path.dirname(dest))

    case File.cp(source_path, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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
