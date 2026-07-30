defmodule Rekindle.Development.Socket do
  @moduledoc false

  @behaviour WebSock

  alias Rekindle.Development.State

  @subscriptions Rekindle.Development.Subscriptions

  @impl WebSock
  def init(project) do
    {:ok, _owner} = Registry.register(@subscriptions, project.root, nil)
    push(project)
  end

  @impl WebSock
  def handle_in({_payload, opcode: _opcode}, project), do: {:ok, project}

  @impl WebSock
  def handle_info({State, :changed}, project), do: push(project)

  def handle_info(_message, project), do: {:ok, project}

  defp push(project) do
    {:push, {:text, Jason.encode!(State.web_status(project))}, project}
  end
end
