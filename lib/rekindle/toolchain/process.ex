defmodule Rekindle.Toolchain.Process do
  @moduledoc false

  @default_output_limit 8_000_000

  @enforce_keys [:status, :output]
  defstruct [:status, :output]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          output: binary()
        }

  @type option_name :: :cd | :env | :output_limit | :timeout
  @type failure ::
          :timeout
          | :output_limit
          | {:invalid_option, option_name()}
          | {:start, Exception.t()}

  @spec run(Path.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, failure()}
  def run(executable, arguments, options \\ []) do
    timeout = Keyword.get(options, :timeout, :infinity)
    output_limit = Keyword.get(options, :output_limit, @default_output_limit)

    with :ok <- validate_options(options, timeout, output_limit),
         {:ok, port} <-
           open_port(executable, arguments, options, output_limit) do
      collect(port, deadline(timeout), output_limit, [], 0)
    end
  end

  defp validate_options(options, timeout, output_limit) do
    cond do
      not (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) ->
        {:error, {:invalid_option, :timeout}}

      not (is_integer(output_limit) and output_limit >= 0) ->
        {:error, {:invalid_option, :output_limit}}

      not (is_binary(options[:cd]) and options[:cd] != "") ->
        {:error, {:invalid_option, :cd}}

      not valid_environment?(Keyword.get(options, :env, [])) ->
        {:error, {:invalid_option, :env}}

      true ->
        :ok
    end
  end

  defp valid_environment?(values) when is_list(values) or is_map(values) do
    Enum.all?(values, fn
      {key, value} when is_binary(key) and is_binary(value) -> true
      _value -> false
    end)
  end

  defp valid_environment?(_values), do: false

  defp open_port(executable, arguments, options, output_limit) do
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
        cd: options[:cd]
      ] ++ environment(options)

    port =
      MuonTrap.muontrap_path()
      |> String.to_charlist()
      |> then(&Port.open({:spawn_executable, &1}, port_options))

    {:ok, port}
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:start, error}}
  end

  defp collect(port, deadline, limit, chunks, size) do
    receive do
      {^port, {:data, data}} ->
        case append(chunks, size, data, limit) do
          {:ok, chunks, size} ->
            collect(port, deadline, limit, chunks, size)

          :output_limit ->
            close(port)
            {:error, :output_limit}
        end

      {^port, {:exit_status, status}} ->
        result(status, chunks)
    after
      remaining(deadline) ->
        close(port)
        {:error, :timeout}
    end
  end

  defp result(status, chunks) do
    {:ok,
     %__MODULE__{
       status: status,
       output: chunks |> Enum.reverse() |> IO.iodata_to_binary()
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

  defp append(chunks, size, data, limit) when size + byte_size(data) <= limit do
    {:ok, [data | chunks], size + byte_size(data)}
  end

  defp append(_chunks, _size, _data, _limit), do: :output_limit

  defp environment(options) do
    case Keyword.get(options, :env, []) do
      [] ->
        []

      values ->
        [env: Enum.map(values, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)]
    end
  end
end
