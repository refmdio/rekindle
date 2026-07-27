defmodule SlintExample.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Rekindle, [otp_app: :slint_example, endpoint: SlintExampleWeb.Endpoint]},
      SlintExampleWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:slint_example, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SlintExample.PubSub},
      # Start a worker by calling: SlintExample.Worker.start_link(arg)
      # {SlintExample.Worker, arg},
      # Start to serve requests, typically the last entry
      SlintExampleWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SlintExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SlintExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
