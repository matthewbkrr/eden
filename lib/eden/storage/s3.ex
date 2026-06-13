defmodule Eden.Storage.S3 do
  @moduledoc """
  S3-compatible object-storage adapter (production). Speaks the S3 REST API over
  `Req` with hand-rolled AWS Signature V4 (`Eden.Storage.SigV4` — no SDK), so it
  works against AWS S3 and compatible services (MinIO, Cloudflare R2, Backblaze
  B2) with no extra dependency. Path-style addressing (`<endpoint>/<bucket>/<key>`)
  for the broadest compatibility.

  Swap to it in one config line (see `config/runtime.exs`):

      config :eden, Eden.Storage, adapter: Eden.Storage.S3
      config :eden, Eden.Storage.S3,
        bucket: "...",
        # The bucket's real region for AWS (e.g. "eu-central-1"); "auto" for R2/MinIO.
        region: "eu-central-1",
        endpoint: "https://s3.eu-central-1.amazonaws.com",
        access_key_id: "...",
        secret_access_key: "..."

  `local_path/1` is intentionally NOT implemented: the facade then returns
  `:error`, so file serving streams the object bytes instead of expecting a path.
  """
  @behaviour Eden.Storage

  alias Eden.Storage.SigV4

  @service "s3"

  @impl true
  # The source is a server-assigned upload temp, not a user-supplied path. Reads
  # the whole object into memory (bounded by the upload caps — ≤50 MB) because
  # SigV4 hashes the full payload for x-amz-content-sha256; a streaming
  # UNSIGNED-PAYLOAD path is a future optimization, not needed at this scale.
  # sobelow_skip ["Traversal.FileModule"]
  def put(key, source_path) do
    case File.read(source_path) do
      {:ok, bytes} -> put_binary(key, bytes)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put_binary(key, binary) do
    case request(:put, key, binary) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def read(key) do
    case request(:get, key, "") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    # Idempotent: a missing object (404) is success, like the local adapter.
    case request(:delete, key, "") do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(key), do: match?({:ok, %{status: 200}}, request(:head, key, ""))

  # Build the path-style URL, sign it (SigV4), and send via Req. The signed
  # `host` matches the URL's host (Req sets the Host header from the URL), and
  # x-amz-date / x-amz-content-sha256 are sent explicitly because they're signed.
  defp request(method, key, body) do
    cfg = config()
    url = "#{cfg.endpoint}/#{cfg.bucket}/#{key}"
    uri = URI.parse(url)
    amz_date = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    payload = SigV4.payload_hash(body)

    auth =
      SigV4.authorization(
        method,
        uri,
        %{
          "host" => host_header(uri),
          "x-amz-date" => amz_date,
          "x-amz-content-sha256" => payload
        },
        payload,
        amz_date: amz_date,
        region: cfg.region,
        service: @service,
        access_key_id: cfg.access_key_id,
        secret_access_key: cfg.secret_access_key
      )

    Req.request(
      [
        method: method,
        url: url,
        headers: [
          {"authorization", auth},
          {"x-amz-date", amz_date},
          {"x-amz-content-sha256", payload}
        ],
        body: body,
        # raw: pin the response to the exact stored bytes (no decode/decompress).
        raw: true
      ] ++ cfg.req_options
    )
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    default = if scheme == "https", do: 443, else: 80
    if port in [nil, default], do: host, else: "#{host}:#{port}"
  end

  defp config do
    cfg = Application.fetch_env!(:eden, __MODULE__)

    %{
      bucket: Keyword.fetch!(cfg, :bucket),
      # Required — no silent default: a wrong region is a SignatureDoesNotMatch
      # 403 on AWS, so the operator must set it consciously (R2/MinIO use "auto").
      region: Keyword.fetch!(cfg, :region),
      endpoint: cfg |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/"),
      access_key_id: Keyword.fetch!(cfg, :access_key_id),
      secret_access_key: Keyword.fetch!(cfg, :secret_access_key),
      # Tests inject `plug: {Req.Test, Eden.Storage.S3}` here; prod leaves it empty.
      req_options: Keyword.get(cfg, :req_options, [])
    }
  end
end
