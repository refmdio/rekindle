defmodule Rekindle.Toolchain.Process do
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

    with {:ok, tools} <- process_tools() do
      port_options =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          args: ["--wait", executable | arguments],
          cd: Keyword.fetch!(options, :cd)
        ] ++ environment(options)

      try do
        {:spawn_executable, String.to_charlist(tools.setsid)}
        |> Port.open(port_options)
        |> receive_output(
          System.monotonic_time(:millisecond) + timeout,
          output_limit,
          cancel_ref,
          tools,
          [],
          0,
          false
        )
      rescue
        error -> {:error, {:start, error}}
      end
    end
  end

  defp receive_output(port, deadline, limit, cancel_ref, tools, chunks, size, truncated?) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {chunks, size, truncated?} = append(chunks, size, truncated?, data, limit)
        receive_output(port, deadline, limit, cancel_ref, tools, chunks, size, truncated?)

      {^port, {:exit_status, status}} ->
        {:ok,
         %__MODULE__{
           status: status,
           output: chunks |> Enum.reverse() |> IO.iodata_to_binary(),
           truncated?: truncated?
         }}

      {:rekindle_cancel, ^cancel_ref} when not is_nil(cancel_ref) ->
        stop(port, tools)
        {:error, :cancelled}
    after
      remaining ->
        stop(port, tools)
        {:error, :timeout}
    end
  end

  defp append(chunks, size, truncated?, data, limit) when size < limit do
    kept = binary_part(data, 0, min(byte_size(data), limit - size))
    {[kept | chunks], size + byte_size(kept), truncated? or byte_size(kept) < byte_size(data)}
  end

  defp append(chunks, size, _truncated?, _data, _limit), do: {chunks, size, true}

  defp stop(port, tools) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    if os_pid do
      group_pid = session_group_pid(os_pid)
      signal(group_pid, "TERM", tools)
      await_exit(port, @termination_grace)
      signal(group_pid, "KILL", tools)
      await_group_exit(group_pid, @termination_grace, tools)
    end

    if Port.info(port) do
      if os_pid, do: signal_process(os_pid, "KILL", tools)
      Port.close(port)
    end
  end

  defp session_group_pid(os_pid) do
    case File.read_link("/proc/#{os_pid}/exe") do
      {:ok, executable} ->
        if Path.basename(executable) == "setsid" do
          session_child_pid(os_pid)
        else
          os_pid
        end

      {:error, _reason} ->
        os_pid
    end
  end

  defp session_child_pid(os_pid) do
    children = "/proc/#{os_pid}/task/#{os_pid}/children"

    with {:ok, contents} <- File.read(children),
         [child | _] <- String.split(contents, ~r/\s+/, trim: true),
         {pid, ""} <- Integer.parse(child) do
      pid
    else
      _ -> os_pid
    end
  end

  defp signal(os_pid, name, tools) do
    case System.cmd(tools.pkill, ["-#{name}", "-g", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      _ ->
        signal_process(os_pid, name, tools)
        :ok
    end
  end

  defp signal_process(os_pid, name, tools) do
    System.cmd(tools.kill, ["-#{name}", Integer.to_string(os_pid)], stderr_to_stdout: true)
  end

  defp await_group_exit(group_pid, timeout, tools) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_group_exit_until(group_pid, deadline, tools)
  end

  defp await_group_exit_until(group_pid, deadline, tools) do
    case System.cmd(tools.pgrep, ["-g", Integer.to_string(group_pid)], stderr_to_stdout: true) do
      {_output, 1} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(10)
          await_group_exit_until(group_pid, deadline, tools)
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

  defp process_tools do
    Enum.reduce_while([:setsid, :pkill, :pgrep, :kill], {:ok, %{}}, fn name, {:ok, tools} ->
      case System.find_executable(Atom.to_string(name)) do
        nil ->
          error = RuntimeError.exception("#{name} executable was not found")
          {:halt, {:error, {:start, error}}}

        path ->
          {:cont, {:ok, Map.put(tools, name, path)}}
      end
    end)
  end
end
