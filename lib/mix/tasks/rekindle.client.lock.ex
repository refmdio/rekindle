defmodule Mix.Tasks.Rekindle.Client.Lock do
  @shortdoc false

  use Mix.Task

  alias Rekindle.Toolchain.Rustup

  @web_toolchain "nightly-2026-04-01"

  @impl Mix.Task
  def run([client_root]) do
    manifest = client_root |> Path.expand() |> Path.join("Cargo.toml")

    with {:ok, rustup} <- Rustup.resolve(),
         {_output, 0} <-
           System.cmd(
             rustup,
             [
               "run",
               @web_toolchain,
               "cargo",
               "generate-lockfile",
               "--manifest-path",
               manifest
             ],
             stderr_to_stdout: true
           ) do
      :ok
    else
      {:error, failure} -> Mix.raise(failure.message)
      {output, status} -> Mix.raise("Cargo.lock generation failed (#{status}): #{output}")
    end
  end

  def run(_argv), do: Mix.raise("usage: mix rekindle.client.lock CLIENT_ROOT")
end
