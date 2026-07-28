defmodule EguiExample.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EguiExampleWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:egui_example, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: EguiExample.PubSub},
      # Start a worker by calling: EguiExample.Worker.start_link(arg)
      # {EguiExample.Worker, arg},
      # Start to serve requests, typically the last entry
      EguiExampleWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EguiExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EguiExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
