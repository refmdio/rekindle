defmodule Mix.Tasks.Rekindle.Check do
  use Mix.Task

  @shortdoc "Checks Rust formatting and lints"
  @moduledoc """
  Checks the generated Rust UI project with its declared Cargo toolchain.

      mix rekindle.check

  The task checks formatting and runs Clippy for every enabled target. Rust
  tests run as part of the application's regular `mix test` suite.
  """

  @impl Mix.Task
  def run([]) do
    otp_app = Mix.Project.config()[:app]

    case Rekindle.Check.run(otp_app,
           project_root: File.cwd!(),
           notify: &notify/2
         ) do
      :ok ->
        :ok

      {:error, error} ->
        output = Map.get(error, :output, "")
        if output != "", do: Mix.shell().error(output)
        Mix.raise(Exception.message(error))
    end
  end

  def run(_arguments), do: Mix.raise("usage: mix rekindle.check")

  defp notify(:start, label), do: Mix.shell().info("Checking #{label}...")
  defp notify(:ok, label), do: Mix.shell().info("Checked #{label}")
end
