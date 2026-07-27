defmodule Rekindle.Toolchain.Process do
  @moduledoc false

  @default_output_limit 8_000_000

  @enforce_keys [:status, :output, :truncated?]
  defstruct [:status, :output, :truncated?]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          output: binary(),
          truncated?: boolean()
        }

  @type failure :: :timeout | {:start, Exception.t()}

  @spec run(Path.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, failure()}
  def run(executable, arguments, options \\ []) do
    output_limit = Keyword.get(options, :output_limit, @default_output_limit)

    port_options =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: [
          "--capture-output",
          "--capture-stderr",
          "--stdio-window",
          Integer.to_string(output_limit + 1),
          "--",
          executable
          | arguments
        ],
        cd: Keyword.fetch!(options, :cd)
      ] ++ environment(options)

    try do
      port =
        MuonTrap.muontrap_path()
        |> String.to_charlist()
        |> then(&Port.open({:spawn_executable, &1}, port_options))

      collect(
        port,
        deadline(Keyword.get(options, :timeout, :infinity)),
        output_limit,
        [],
        0,
        false
      )
    rescue
      error -> {:error, {:start, error}}
    end
  end

  defp collect(port, deadline, limit, chunks, size, truncated?) do
    receive do
      {^port, {:data, data}} ->
        {chunks, size, truncated?} = append(chunks, size, truncated?, data, limit)

        if truncated? do
          close(port)
          result(0, chunks, true)
        else
          collect(port, deadline, limit, chunks, size, false)
        end

      {^port, {:exit_status, status}} ->
        result(status, chunks, truncated?)
    after
      remaining(deadline) ->
        close(port)
        {:error, :timeout}
    end
  end

  defp result(status, chunks, truncated?) do
    {:ok,
     %__MODULE__{
       status: status,
       output: chunks |> Enum.reverse() |> IO.iodata_to_binary(),
       truncated?: truncated?
     }}
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp append(chunks, size, truncated?, data, limit) when size < limit do
    kept = binary_part(data, 0, min(byte_size(data), limit - size))
    {[kept | chunks], size + byte_size(kept), truncated? or byte_size(kept) < byte_size(data)}
  end

  defp append(chunks, size, _truncated?, _data, _limit), do: {chunks, size, true}

  defp environment(options) do
    case Keyword.get(options, :env, []) do
      [] ->
        []

      values ->
        [env: Enum.map(values, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)]
    end
  end
end
