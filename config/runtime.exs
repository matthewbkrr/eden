import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/eden start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :eden, EdenWeb.Endpoint, server: true
end

config :eden, EdenWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :eden, Eden.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Encryption-at-rest key for Eden.Vault (#250, TOTP secrets). Defaults to a value
  # derived from SECRET_KEY_BASE so no new required env var — set EDEN_VAULT_KEY to a
  # dedicated secret if you ever want to rotate it independently of the session key.
  config :eden, Eden.Vault,
    key: System.get_env("EDEN_VAULT_KEY") || secret_key_base <> "eden.vault"

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public host — the server IP (initial phase) or chat.ihi.ru.
      """

  # Scheme/port are env-driven so the SAME release runs over plain HTTP by IP
  # (the initial bring-up, before a domain) and over HTTPS by domain (Caddy
  # terminates TLS) with no recompile — flip PHX_SCHEME/PHX_HOST and restart.
  # They drive URL generation AND the LiveView socket's check_origin.
  scheme = System.get_env("PHX_SCHEME") || "https"

  scheme in ~w(http https) ||
    raise ~s|PHX_SCHEME must be "http" or "https", got: #{inspect(scheme)}|

  default_url_port = if scheme == "https", do: "443", else: "80"
  url_port = String.to_integer(System.get_env("PHX_PORT") || default_url_port)

  config :eden, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Uploads live on a persistent volume in prod — the dev default is a relative
  # path that an ephemeral release filesystem can't keep. Point EDEN_UPLOADS_ROOT
  # at a mounted volume. Swap to an S3-compatible adapter here when object storage
  # lands (see "Security follow-ups" in CLAUDE.md).
  config :eden, Eden.Storage.Local,
    root: System.get_env("EDEN_UPLOADS_ROOT") || "/var/lib/eden/uploads"

  # Object storage (#55): set EDEN_S3_BUCKET to swap the storage adapter to the
  # S3-compatible one (AWS S3 / Cloudflare R2 / MinIO / B2). Without it, the Local
  # adapter (above) keeps using EDEN_UPLOADS_ROOT. Callers never change. It's
  # all-or-nothing: once the bucket is set, the other vars are required (a partial
  # config fails the boot loudly rather than silently mis-signing). REGION must be
  # the bucket's real region on AWS (a wrong region is a 403 on every request);
  # use "auto" for Cloudflare R2 / MinIO.
  #
  # A PRESENT-BUT-EMPTY var counts as unset (#85): docker compose passes
  # `EDEN_S3_BUCKET=` (empty string) when no bucket is set, and "" is truthy in
  # Elixir — without this guard the S3 adapter would be selected with an empty
  # endpoint and every attachment upload would crash ("scheme is required").
  if (bucket = System.get_env("EDEN_S3_BUCKET")) not in [nil, ""] do
    config :eden, Eden.Storage, adapter: Eden.Storage.S3

    config :eden, Eden.Storage.S3,
      bucket: bucket,
      region: System.fetch_env!("EDEN_S3_REGION"),
      endpoint: System.fetch_env!("EDEN_S3_ENDPOINT"),
      access_key_id: System.fetch_env!("EDEN_S3_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("EDEN_S3_SECRET_ACCESS_KEY")
  end

  config :eden, EdenWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :eden, EdenWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # NOTE: eden intentionally does NOT set `force_ssl` (#85). TLS terminates at
  # the reverse proxy (Caddy — see deploy/), which owns the http→https redirect +
  # HSTS; the release runs plain HTTP internally so one image serves both the
  # bare-IP/HTTP bring-up and the HTTPS-by-domain phase. `Plug.RewriteOn` in the
  # endpoint trusts Caddy's X-Forwarded-Proto so the scheme (→ Secure cookie)
  # stays correct.
end
