defmodule Eden.Storage.SigV4 do
  @moduledoc """
  AWS **Signature Version 4** signing for S3 requests — hand-rolled with `:crypto`
  (no SDK / extra dependency), so `Eden.Storage.S3` stays within the project's
  Req-only HTTP rule. Pure functions; verified against the AWS spec's published
  example vector in the tests.
  """

  @doc "Lowercase hex SHA-256 of a request payload (the `x-amz-content-sha256` value)."
  def payload_hash(body), do: hex(sha256(body))

  @doc """
  The `Authorization` header value for a signed S3 request.

  `headers` is a map of the headers to sign (lowercased names → values; must
  include `host`, `x-amz-date`, `x-amz-content-sha256`). `opts`:
  `:amz_date` ("YYYYMMDDTHHMMSSZ"), `:region`, `:service`, `:access_key_id`,
  `:secret_access_key`.
  """
  def authorization(method, %URI{} = uri, headers, payload_hash, opts) do
    amz_date = Keyword.fetch!(opts, :amz_date)
    date = String.slice(amz_date, 0, 8)
    region = Keyword.fetch!(opts, :region)
    service = Keyword.fetch!(opts, :service)
    access = Keyword.fetch!(opts, :access_key_id)
    secret = Keyword.fetch!(opts, :secret_access_key)

    signed = headers |> Map.keys() |> Enum.sort()
    signed_headers = Enum.join(signed, ";")
    canonical_headers = Enum.map_join(signed, "", fn h -> "#{h}:#{canon_value(headers[h])}\n" end)

    canonical_request =
      Enum.join(
        [
          method |> to_string() |> String.upcase(),
          canonical_path(uri.path),
          canonical_query(uri.query),
          canonical_headers,
          signed_headers,
          payload_hash
        ],
        "\n"
      )

    scope = "#{date}/#{region}/#{service}/aws4_request"

    string_to_sign =
      Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, hex(sha256(canonical_request))], "\n")

    signature = secret |> signing_key(date, region, service) |> hmac(string_to_sign) |> hex()

    "AWS4-HMAC-SHA256 Credential=#{access}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
  end

  # kSecret → kDate → kRegion → kService → kSigning (the SigV4 HMAC chain).
  defp signing_key(secret, date, region, service) do
    ("AWS4" <> secret) |> hmac(date) |> hmac(region) |> hmac(service) |> hmac("aws4_request")
  end

  defp canonical_path(p) when p in [nil, ""], do: "/"
  defp canonical_path(path), do: path |> String.split("/") |> Enum.map_join("/", &uri_encode/1)

  defp canonical_query(q) when q in [nil, ""], do: ""

  # The query is taken as ALREADY encoded (AWS's rule) and only split + sorted —
  # never decoded-then-re-encoded, which would corrupt a literal `+`/`%2B`. (No
  # object op here carries a query; this keeps the signer correct if it's ever
  # reused for presigned URLs / list-objects.)
  defp canonical_query(query) do
    query
    |> String.split("&")
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, ""}
      end
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  # AWS uri-encode: only the unreserved set (A-Za-z0-9 - _ . ~) stays literal.
  defp uri_encode(s) do
    URI.encode(s, &(&1 in ?A..?Z or &1 in ?a..?z or &1 in ?0..?9 or &1 in [?-, ?_, ?., ?~]))
  end

  # Trim and collapse internal runs of spaces (SigV4 header-value canonicalization).
  defp canon_value(v), do: v |> to_string() |> String.trim() |> String.replace(~r/ +/, " ")

  defp sha256(data), do: :crypto.hash(:sha256, data)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)
end
