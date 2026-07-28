defmodule Mix.Tasks.Rekindle.Dev do
  @shortdoc "Start the Rekindle development runtime"
  @moduledoc """
  Starts the Rekindle file watcher and development builders without starting an
  HTTP server.

  The optional target selection must be `web`, `desktop`, or `web,desktop`.
  With no selection, Web is preferred when enabled; otherwise desktop is used.

      mix rekindle.dev
      mix rekindle.dev desktop
      mix rekindle.dev web,desktop

  Phoenix applications normally let `Rekindle.DevServer` start Web development
  on the first request. Run this task directly for desktop development or when
  an HTTP server is not involved.
  """

  use Mix.Task

  @targets %{"web" => :web, "desktop" => :desktop}

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("app.start")

    otp_app = Keyword.fetch!(Mix.Project.config(), :app)
    requested = parse_targets!(arguments)

    case Rekindle.Development.ensure_started(otp_app: otp_app, targets: requested) do
      {:ok, supervisor} ->
        wait(supervisor)

      {:error, reason} ->
        Mix.raise("could not start Rekindle development: #{error_message(reason)}")
    end
  end

  @doc false
  @spec parse_targets!([String.t()]) :: nil | [:web | :desktop]
  def parse_targets!([]), do: nil

  def parse_targets!([selection]) do
    names = String.split(selection, ",", trim: true)

    with true <- names != [],
         true <- length(names) == length(Enum.uniq(names)),
         {:ok, targets} <- fetch_targets(names) do
      Enum.filter([:web, :desktop], &(&1 in targets))
    else
      _error -> Mix.raise("expected a single target selection: web, desktop, or web,desktop")
    end
  end

  def parse_targets!(_arguments) do
    Mix.raise("expected a single target selection: web, desktop, or web,desktop")
  end

  defp fetch_targets(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, targets} ->
      case Map.fetch(@targets, name) do
        {:ok, target} -> {:cont, {:ok, [target | targets]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp wait(_supervisor) do
    unless iex_running?(), do: Process.sleep(:infinity)
  end

  @dialyzer {:nowarn_function, iex_running?: 0}
  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end

  defp error_message(reason) do
    if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
  end
end
