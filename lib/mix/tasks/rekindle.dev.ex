defmodule Mix.Tasks.Rekindle.Dev do
  @shortdoc "Start Phoenix with Rekindle development services"
  @moduledoc """
  Starts Phoenix with Rekindle's supervised development services.

      mix rekindle.dev

  Additional arguments are forwarded unchanged to `mix phx.server`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("phx.server", arguments)
  end
end
