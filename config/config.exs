# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :eden,
  ecto_repos: [Eden.Repo],
  generators: [timestamp_type: :utc_datetime]

# Oban — background jobs persisted in Postgres. Queues stay minimal for now;
# add more as features need them (e.g. media processing in Phase 3).
config :eden, Oban,
  repo: Eden.Repo,
  queues: [default: 10, media: 5],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]

# Blob storage. Local disk on dev; swap the adapter (S3-compatible) in prod via
# config without touching callers. See Eden.Storage.
config :eden, Eden.Storage, adapter: Eden.Storage.Local
config :eden, Eden.Storage.Local, root: "priv/uploads"

# Configure the endpoint
config :eden, EdenWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EdenWeb.ErrorHTML, json: EdenWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Eden.PubSub,
  live_view: [signing_salt: "vEgj3gMU"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  eden: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  eden: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Internationalization: supported UI locales. Actual locale per request is
# resolved by EdenWeb.Locale (session choice → Accept-Language → this default).
config :gettext, :default_locale, "en"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
