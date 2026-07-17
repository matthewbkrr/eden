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

  @doc """
  Optional: a local filesystem path for `key`, when the adapter is disk-backed.
  Lets callers stream via `Plug.Conn.send_file/3` instead of reading the whole
  object into memory. Remote adapters (e.g. S3) return `:error`.
  """
  @callback local_path(key) :: {:ok, Path.t()} | :error

  @doc """
  Optional: read just the inclusive byte range `first..last` of `key`, so a remote
  adapter can pull only the requested window (a `<video>` seek) instead of the whole
  object. The facade falls back to `read/1` + slice for adapters that don't implement it.
  """
  @callback read_range(key, {first :: non_neg_integer, last :: non_neg_integer}) ::
              {:ok, binary} | {:error, term}
  @optional_callbacks local_path: 1, read_range: 2

  @doc "Store the file at `source_path` under `key`."
  def put(key, source_path), do: adapter().put(key, source_path)

  @doc "Store in-memory `binary` bytes under `key` (e.g. a generated thumbnail)."
  def put_binary(key, binary), do: adapter().put_binary(key, binary)

  @doc "A local filesystem path for `key`, or `:error` if the adapter isn't disk-backed."
  def local_path(key) do
    adapter = adapter()

    if loaded_exported?(adapter, :local_path, 1), do: adapter.local_path(key), else: :error
  end

  @doc """
  Read the inclusive byte range `first..last` of `key`. Uses the adapter's `read_range/2`
  when implemented (a single ranged GET for S3); otherwise reads the whole object and slices
  (correctness over efficiency — the disk-backed adapter serves ranges via sendfile anyway).
  """
  def read_range(key, {first, last}) do
    adapter = adapter()

    if loaded_exported?(adapter, :read_range, 2) do
      adapter.read_range(key, {first, last})
    else
      with {:ok, bytes} <- adapter.read(key), do: slice(bytes, first, last)
    end
  end

  defp slice(bytes, first, last) do
    total = byte_size(bytes)

    if first < total,
      do: {:ok, binary_part(bytes, first, min(last, total - 1) - first + 1)},
      else: {:error, :range}
  end

  # `function_exported?/3` returns false for a not-yet-loaded module, so a first call after a
  # restart (before any `put`) could wrongly see `false` and skip the disk fast-path (#374/R159).
  # `Code.ensure_loaded?/1` forces the BEAM file in first (a no-op in an embedded release).
  defp loaded_exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

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
