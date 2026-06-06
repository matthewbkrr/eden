import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :eden, Eden.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "eden_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Oban in tests: no queues or plugins; jobs are asserted with Oban.Testing.
config :eden, Oban, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :eden, EdenWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pZ/7aP9o7RQJs/z9OTBQ/h2Hb9IghObb0/5saQGyumWBUez9HNq1jpVSy6WTSsNu",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
