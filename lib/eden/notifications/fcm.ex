defmodule Eden.Notifications.FCM do
  @moduledoc """
  FCM push transport (#418, ADR-0001 Decision 2): Android notifications via the
  FCM **HTTP v1 API** called directly — the free push channel only, no Firebase
  platform adoption (see the ADR's cost note). GMS-less devices are #421's
  RuStore fallback.

  As an `Eden.Notifications.Adapter`, `deliver/2` only enqueues a `PushWorker`
  job; the worker calls `push/2`. Auth is a service-account OAuth2 token: a
  RS256 self-signed JWT exchanged at the account's `token_uri`, cached in
  `:persistent_term` for ~50 min of its 60-minute life. RS256 signatures from
  `:public_key.sign/3` are already the raw form JWT wants — no DER unpacking
  (unlike APNs' ES256).

  Config (set from env in `config/runtime.exs`, absent by default):
  `service_account` — the decoded service-account JSON map (`private_key`,
  `client_email`, `project_id`, `token_uri`).
  """
  @behaviour Eden.Notifications.Adapter

  alias Eden.Notifications
  alias Eden.Notifications.PushWorker

  @scope "https://www.googleapis.com/auth/firebase.messaging"

  @impl true
  def deliver(user_id, payload) do
    # Same exists?-gate as APNs: keep the inline send path to an index-only
    # SELECT for recipients with no Android device (#424 review).
    if Notifications.has_targets?(user_id, "fcm") do
      %{user_id: user_id, kind: "fcm", payload: payload}
      |> PushWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  @doc """
  Send one message to one registration token. `:ok` | `:unregistered` (token
  dead — the caller prunes it) | `{:error, reason}` (transient, the job
  retries).
  """
  def push(token, %{title: title, body: body, data: data}) do
    cfg = config!()
    account = Keyword.fetch!(cfg, :service_account)

    with {:ok, access_token} <- oauth_token(cfg, account) do
      message = %{
        "message" => %{
          "token" => token,
          "notification" => %{"title" => title, "body" => body},
          # Deep-link routing payload (#419); FCM requires string→string.
          "data" => data,
          "android" => %{"priority" => "HIGH"}
        }
      }

      req =
        Req.new([auth: {:bearer, access_token}] ++ Keyword.get(cfg, :req_options, []))

      url = "https://fcm.googleapis.com/v1/projects/#{account["project_id"]}/messages:send"

      case Req.post(req, url: url, json: message) do
        {:ok, %{status: 200}} ->
          :ok

        # v1 reports a dead registration as 404/UNREGISTERED.
        {:ok, %{status: 404}} ->
          :unregistered

        # A rejected access token must not sit in the cache for its ~50-min
        # TTL — drop it so the Oban retry re-exchanges (#424 review).
        {:ok, %{status: 401, body: resp}} ->
          :persistent_term.erase({__MODULE__, :oauth})
          {:error, {:fcm, 401, resp}}

        {:ok, %{status: status, body: resp}} ->
          {:error, {:fcm, status, resp}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Service-account OAuth: self-signed RS256 JWT -> access token, cached for
  # ~50 of its 60 minutes.
  defp oauth_token(cfg, account) do
    now = System.system_time(:second)

    case :persistent_term.get({__MODULE__, :oauth}, nil) do
      {token, fetched_at} when now - fetched_at < 50 * 60 ->
        {:ok, token}

      _stale ->
        with {:ok, token} <- fetch_oauth_token(cfg, account, now) do
          :persistent_term.put({__MODULE__, :oauth}, {token, now})
          {:ok, token}
        end
    end
  end

  defp fetch_oauth_token(cfg, account, now) do
    assertion = oauth_assertion(account, now)
    req = Req.new(Keyword.get(cfg, :req_options, []))

    form = [
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: assertion
    ]

    case Req.post(req, url: account["token_uri"], form: form) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      {:ok, %{status: status, body: resp}} -> {:error, {:fcm_oauth, status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp oauth_assertion(account, now) do
    header = b64url(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}))

    claims =
      b64url(
        Jason.encode!(%{
          "iss" => account["client_email"],
          "scope" => @scope,
          "aud" => account["token_uri"],
          "iat" => now,
          "exp" => now + 3600
        })
      )

    message = header <> "." <> claims
    signature = :public_key.sign(message, :sha256, rsa_key!(account["private_key"]))

    message <> "." <> b64url(signature)
  end

  defp rsa_key!(pem),
    do: pem |> :public_key.pem_decode() |> hd() |> :public_key.pem_entry_decode()

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  defp config!, do: Application.fetch_env!(:eden, __MODULE__)
end
