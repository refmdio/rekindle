defmodule Rekindle.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _arguments) do
    children = [
      {Registry, keys: :unique, name: Rekindle.Development.Registry},
      {Registry, keys: :duplicate, name: Rekindle.Development.Subscriptions},
      {DynamicSupervisor, strategy: :one_for_one, name: Rekindle.Development.DynamicSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Rekindle.Supervisor)
  end
end
