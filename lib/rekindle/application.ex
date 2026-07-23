defmodule Rekindle.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Rekindle.RuntimeRegistry},
      Rekindle.QualifiedPath,
      Rekindle.Toolchain.RootAuthority
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Rekindle.Supervisor)
  end
end
