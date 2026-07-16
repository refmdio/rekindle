defmodule Mix.Tasks.Rekindle.Client.Lock do
  @shortdoc false

  use Mix.Task

  alias Rekindle.ClientGenerator

  @impl Mix.Task
  def run([client_root]) do
    case ClientGenerator.generate_lock(client_root) do
      :ok ->
        :ok

      {:error, %Rekindle.Failure{} = failure} ->
        Mix.raise(failure.message)

      {:error, {output, status}} ->
        Mix.raise("Cargo.lock generation failed (#{status}): #{output}")

      {:error, reason} ->
        Mix.raise("Cargo.lock generation failed: #{reason}")
    end
  end

  def run(_argv), do: Mix.raise("usage: mix rekindle.client.lock CLIENT_ROOT")
end
