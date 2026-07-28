defmodule GpuiExample.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GpuiExampleWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:gpui_example, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: GpuiExample.PubSub},
      # Start a worker by calling: GpuiExample.Worker.start_link(arg)
      # {GpuiExample.Worker, arg},
      # Start to serve requests, typically the last entry
      GpuiExampleWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GpuiExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GpuiExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
