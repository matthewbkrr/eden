defmodule Eden.Notifications.APNs do
  @moduledoc """
  APNs push transport (#418, ADR-0001 Decision 2): iOS notifications straight
  to Apple's HTTP/2 endpoint — no SDK, no intermediary, mirroring the
  hand-rolled `Eden.Storage.SigV4` approach.

  As an `Eden.Notifications.Adapter`, `deliver/2` only enqueues a
  `PushWorker` job (the caller is the inline message-send path); the worker
  calls `push/2`, which does the actual HTTP/2 POST via `Req` over the
  `Eden.PushFinch` pool (APNs REQUIRES h2; Req's default pool speaks h1).

  Auth is a provider-token JWT (ES256, the .p8 key from the Apple Developer
  account), cached in `:persistent_term` and reminted after ~45 min (Apple
  accepts 20–60). The ECDSA signature from `:public_key.sign/3` is DER; JWT
  wants raw `r || s`, hence the unpacking below.

  Config (set from env in `config/runtime.exs`, absent by default):
  `key_p8` (PEM), `key_id`, `team_id`, `topic` (the app bundle id), `env`
  (`:prod | :sandbox`).
  """
  @behaviour Eden.Notifications.Adapter

  alias Eden.Notifications.PushWorker

  @impl true
  def deliver(user_id, payload) do
    %{user_id: user_id, kind: "apns", payload: payload}
    |> PushWorker.new()
    |> Oban.insert()

    :ok
  end

  @doc """
  POST one alert to one device token. `:ok` | `:unregistered` (token dead —
  the caller prunes it) | `{:error, reason}` (transient, the job retries).
  """
  def push(token, %{title: title, body: body, data: data}) do
    cfg = config!()

    apns_payload =
      Map.merge(data, %{
        "aps" => %{
          "alert" => %{"title" => title, "body" => body},
          "sound" => "default"
        }
      })

    req =
      Req.new(
        [
          base_url: host(cfg[:env]),
          finch: Eden.PushFinch,
          headers: [
            {"authorization", "bearer " <> jwt(cfg)},
            {"apns-topic", cfg[:topic]},
            {"apns-push-type", "alert"},
            {"apns-priority", "10"}
          ]
        ] ++ Keyword.get(cfg, :req_options, [])
      )

    case Req.post(req, url: "/3/device/#{token}", json: apns_payload) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 410}} -> :unregistered
      {:ok, %{status: 400, body: %{"reason" => "BadDeviceToken"}}} -> :unregistered
      {:ok, %{status: status, body: resp}} -> {:error, {:apns, status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp host(:sandbox), do: "https://api.sandbox.push.apple.com"
  defp host(_prod), do: "https://api.push.apple.com"

  # Apple provider auth: an ES256 JWT minted from the .p8 key. Cached
  # process-globally; :persistent_term GC on replace is fine at a ~45-minute
  # cadence. (Wording avoids "token" right before a dashed word — the gitleaks
  # generic-api-key rule reads that as a hardcoded secret.)
  defp jwt(cfg) do
    now = System.system_time(:second)

    case :persistent_term.get({__MODULE__, :jwt}, nil) do
      {token, issued_at} when now - issued_at < 45 * 60 ->
        token

      _stale ->
        token = sign_jwt(cfg, now)
        :persistent_term.put({__MODULE__, :jwt}, {token, now})
        token
    end
  end

  defp sign_jwt(cfg, now) do
    header = b64url(Jason.encode!(%{"alg" => "ES256", "kid" => cfg[:key_id], "typ" => "JWT"}))
    claims = b64url(Jason.encode!(%{"iss" => cfg[:team_id], "iat" => now}))
    message = header <> "." <> claims

    der = :public_key.sign(message, :sha256, ec_key!(cfg[:key_p8]))
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)

    message <> "." <> b64url(pad32(r) <> pad32(s))
  end

  # Apple ships the key as PKCS#8 ("BEGIN PRIVATE KEY"); pem_entry_decode
  # unwraps it (or a bare "BEGIN EC PRIVATE KEY") to the ECPrivateKey record
  # :public_key.sign/3 wants.
  defp ec_key!(pem), do: pem |> :public_key.pem_decode() |> hd() |> :public_key.pem_entry_decode()

  # P-256 r/s are < 2^256, so encode_unsigned never exceeds 32 bytes.
  defp pad32(int) do
    bin = :binary.encode_unsigned(int)
    :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin
  end

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  defp config!, do: Application.fetch_env!(:eden, __MODULE__)
end
