defmodule Rekindle.Cargo.Process do
  @moduledoc false

  @default_timeout 120_000
  @default_output_limit 8_000_000
  @termination_grace 500

  @enforce_keys [:status, :output, :truncated?]
  defstruct [:status, :output, :truncated?]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          output: binary(),
          truncated?: boolean()
        }

  @type failure :: :cancelled | :timeout | {:start, Exception.t()}

  @spec run(Path.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, failure()}
  def run(executable, arguments, options \\ []) do
    timeout = Keyword.get(options, :timeout, @default_timeout)
    output_limit = Keyword.get(options, :output_limit, @default_output_limit)
    cancel_ref = Keyword.get(options, :cancel_ref)

    port_options =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: arguments,
        cd: Keyword.fetch!(options, :cd)
      ] ++ environment(options)

    try do
      {:spawn_executable, String.to_charlist(executable)}
      |> Port.open(port_options)
      |> receive_output(
        System.monotonic_time(:millisecond) + timeout,
        output_limit,
        cancel_ref,
        [],
        0,
        false
      )
    rescue
      error -> {:error, {:start, error}}
    end
  end

  defp receive_output(port, deadline, limit, cancel_ref, chunks, size, truncated?) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {chunks, size, truncated?} = append(chunks, size, truncated?, data, limit)
        receive_output(port, deadline, limit, cancel_ref, chunks, size, truncated?)

      {^port, {:exit_status, status}} ->
        {:ok,
         %__MODULE__{
           status: status,
           output: chunks |> Enum.reverse() |> IO.iodata_to_binary(),
           truncated?: truncated?
         }}

      {:rekindle_cancel, ^cancel_ref} when not is_nil(cancel_ref) ->
        stop(port)
        {:error, :cancelled}
    after
      remaining ->
        stop(port)
        {:error, :timeout}
    end
  end

  defp append(chunks, size, truncated?, data, limit) when size < limit do
    kept = binary_part(data, 0, min(byte_size(data), limit - size))
    {[kept | chunks], size + byte_size(kept), truncated? or byte_size(kept) < byte_size(data)}
  end

  defp append(chunks, size, _truncated?, _data, _limit), do: {chunks, size, true}

  defp stop(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    if os_pid do
      signal(os_pid, "TERM")
      await_exit(port, @termination_grace)
    end

    if Port.info(port) do
      if os_pid do
        signal(os_pid, "KILL")
        await_exit(port, @termination_grace)
      end
    end

    if Port.info(port) do
      Port.close(port)
    end
  end

  defp signal(os_pid, name) do
    case System.find_executable("kill") do
      nil ->
        :unavailable

      executable ->
        case System.cmd(executable, ["-#{name}", "--", "-#{os_pid}"], stderr_to_stdout: true) do
          {_output, 0} ->
            :ok

          _ ->
            System.cmd(executable, ["-#{name}", Integer.to_string(os_pid)],
              stderr_to_stdout: true
            )

            :ok
        end
    end
  end

  defp await_exit(port, timeout) do
    receive do
      {^port, {:data, _data}} -> await_exit(port, timeout)
      {^port, {:exit_status, _status}} -> :ok
    after
      timeout -> :timeout
    end
  end

  defp environment(options) do
    case Keyword.get(options, :env, []) do
      [] ->
        []

      values ->
        [env: Enum.map(values, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)]
    end
  end
end
