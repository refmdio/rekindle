defmodule Mix.Tasks.Rekindle.Dev do
  @shortdoc "Start Phoenix with Rekindle development services"
  @moduledoc @shortdoc

  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("phx.server", arguments)
  end
end
