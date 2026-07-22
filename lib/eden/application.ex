defmodule Eden.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Log Oban job lifecycle events through the structured Logger.
    Oban.Telemetry.attach_default_logger()

    children = [
      EdenWeb.Telemetry,
      Eden.Repo,
      {DNSCluster, query: Application.get_env(:eden, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Eden.PubSub},
      # Owns the login/invite throttle ETS table (#236); must be up before the endpoint.
      Eden.RateLimit,
      EdenWeb.Presence,
      # HTTP/2 pools for the APNs push transport (#418) — APNs requires h2 and
      # Req's default Finch pool speaks h1. Always in the tree: connections open
      # lazily, so without push keys this costs nothing.
      {Finch,
       name: Eden.PushFinch,
       pools: %{
         "https://api.push.apple.com" => [protocols: [:http2]],
         "https://api.sandbox.push.apple.com" => [protocols: [:http2]]
       }},
      {Oban, Application.fetch_env!(:eden, Oban)},
      # Start to serve requests, typically the last entry
      EdenWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Eden.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EdenWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
