defmodule IcedExample.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      IcedExampleWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:iced_example, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: IcedExample.PubSub},
      # Start a worker by calling: IcedExample.Worker.start_link(arg)
      # {IcedExample.Worker, arg},
      # Start to serve requests, typically the last entry
      IcedExampleWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: IcedExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IcedExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
