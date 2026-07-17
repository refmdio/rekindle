defmodule Rekindle.ProcessRunner.Adapter do
  @moduledoc false

  @callback run_exec(Path.t(), map(), Rekindle.Toolchain.Exec.t(), keyword()) ::
              {:ok, map(), binary(), binary()} | {:error, atom()}
  @callback cancel(port(), map()) :: :ok | {:error, atom()}
end

defmodule Rekindle.ProcessRunner.DefaultAdapter do
  @moduledoc false
  @behaviour Rekindle.ProcessRunner.Adapter

  alias Rekindle.Toolchain.{Exec, Helper}

  @impl true
  def run_exec(helper, spawn, state, options),
    do: Helper.run_exec(helper, spawn, state, options)

  @impl true
  def cancel(port, header) when is_port(port) do
    with {:ok, bytes} <- Exec.encode(header),
         true <- Port.command(port, bytes) do
      :ok
    else
      _ -> {:error, :helper_io}
    end
  rescue
    ArgumentError -> {:error, :helper_io}
  end
end
