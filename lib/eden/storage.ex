defmodule Eden.Storage do
  @moduledoc """
  Blob storage facade and behaviour. Callers use `Eden.Storage.put/read/delete`;
  the concrete adapter (Local on dev, S3-compatible in prod) is chosen by config
  and is never referenced directly. Objects are addressed by an opaque key — the
  app stores only that key + metadata, never a path or a storage implementation.
  """
  @type key :: String.t()

  @callback put(key, source_path :: Path.t()) :: :ok | {:error, term}
  @callback put_binary(key, binary) :: :ok | {:error, term}
  @callback read(key) :: {:ok, binary} | {:error, term}
  @callback delete(key) :: :ok | {:error, term}
  @callback exists?(key) :: boolean

  @doc "Store the file at `source_path` under `key`."
  def put(key, source_path), do: adapter().put(key, source_path)

  @doc "Store in-memory `binary` bytes under `key` (e.g. a generated thumbnail)."
  def put_binary(key, binary), do: adapter().put_binary(key, binary)

  @doc "Read the object's bytes."
  def read(key), do: adapter().read(key)

  @doc "Delete the object (idempotent)."
  def delete(key), do: adapter().delete(key)

  @doc "Whether the object exists."
  def exists?(key), do: adapter().exists?(key)

  @doc """
  A random, collision-resistant object key: `"<prefix>/<random>.<ext>"`. The
  random component avoids guessable keys and the prefix groups related objects.
  """
  def build_key(prefix, ext) do
    random = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{prefix}/#{random}.#{ext}"
  end

  defp adapter, do: Application.fetch_env!(:eden, __MODULE__)[:adapter]
end
