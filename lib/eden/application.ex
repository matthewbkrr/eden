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
      EdenWeb.Presence,
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
