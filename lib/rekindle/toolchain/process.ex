defmodule Rekindle.Toolchain.Process do
  @moduledoc false

  @default_timeout 120_000
  @default_output_limit 8_000_000
  @termination_grace 500
  @probe_grace 200
  @probe_reap_grace 20
  @probe_natural_exit 1_500
  @probe_executables ["/usr/bin/sleep", "/bin/sleep"]

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

      if await_group_exit(group_pid, @termination_grace) == :timeout do
        signal_group_members(group_pid, "KILL", tools)
        await_group_exit(group_pid, @termination_grace)
      end
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
        signal_group_members(os_pid, name, tools)
        :ok
    end
  end

  defp signal_group_members(group_pid, name, tools) do
    group_pid
    |> group_members()
    |> Enum.each(&signal_process(&1, name, tools))
  end

  defp signal_process(os_pid, name, tools) do
    System.cmd(tools.kill, ["-#{name}", Integer.to_string(os_pid)], stderr_to_stdout: true)
  end

  defp await_group_exit(group_pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_group_exit_until(group_pid, deadline)
  end

  defp await_group_exit_until(group_pid, deadline) do
    if group_members(group_pid) == [] do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(10)
        await_group_exit_until(group_pid, deadline)
      end
    end
  end

  defp group_members(group_pid) do
    "/proc/[0-9]*/stat"
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, stat} <- File.read(path),
           {:ok, ^group_pid} <- process_group_pid(stat),
           {pid, ""} <- path |> Path.dirname() |> Path.basename() |> Integer.parse() do
        [pid]
      else
        _ -> []
      end
    end)
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
    with {:ok, tools} <-
           Enum.reduce_while(
             [:setsid, :pkill, :kill],
             {:ok, %{}},
             fn name, {:ok, tools} ->
               case System.find_executable(Atom.to_string(name)) do
                 nil ->
                   error = RuntimeError.exception("#{name} executable was not found")
                   {:halt, {:error, {:start, error}}}

                 path ->
                   {:cont, {:ok, Map.put(tools, name, path)}}
               end
             end
           ),
         :ok <- verify_process_tools(tools) do
      {:ok, tools}
    end
  end

  defp verify_process_tools(tools) do
    with :ok <- verify_signal(tools, :group),
         :ok <- verify_signal(tools, :process) do
      :ok
    else
      _ ->
        error = RuntimeError.exception("process group controls are not operational")
        {:error, {:start, error}}
    end
  end

  defp verify_signal(tools, kind) do
    probe = Enum.find(@probe_executables, &File.exists?/1)

    if is_nil(probe), do: raise("probe executable was not found")

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(tools.setsid)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          args: ["--wait", probe, "1"],
          cd: "/"
        ]
      )

    process_pid = probe_process_pid(port, @probe_grace)

    signal_result =
      case {kind, process_pid} do
        {:group, pid} when is_integer(pid) ->
          System.cmd(tools.pkill, ["-TERM", "-g", Integer.to_string(pid)], stderr_to_stdout: true)

        {:process, pid} when is_integer(pid) ->
          System.cmd(tools.kill, ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

        _ ->
          {"", 1}
      end

    exited = await_process_exit(process_pid, @probe_grace)

    finish_probe(port, exited)

    if match?({_output, 0}, signal_result) and exited == :ok, do: :ok, else: :error
  rescue
    _error -> :error
  end

  defp await_process_exit(pid, timeout) when is_integer(pid) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_process_exit_until(pid, deadline)
  end

  defp await_process_exit(_pid, _timeout), do: :timeout

  defp await_process_exit_until(pid, deadline) do
    if File.exists?("/proc/#{pid}") do
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(5)
        await_process_exit_until(pid, deadline)
      end
    else
      :ok
    end
  end

  defp finish_probe(port, :ok) do
    if await_exit(port, @probe_reap_grace) == :timeout and Port.info(port) do
      Port.close(port)
    end
  end

  defp finish_probe(port, :timeout) do
    if await_exit(port, @probe_natural_exit) == :timeout and Port.info(port) do
      Port.close(port)
    end
  end

  defp probe_process_pid(port, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    probe_process_pid_until(port, deadline)
  end

  defp probe_process_pid_until(port, deadline) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        case probe_group_leader(os_pid) do
          {:ok, pid} -> pid
          :error -> retry_probe_pid(port, deadline)
        end

      _ ->
        nil
    end
  end

  defp retry_probe_pid(port, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      nil
    else
      Process.sleep(5)
      probe_process_pid_until(port, deadline)
    end
  end

  defp probe_group_leader(os_pid) do
    with {:ok, stat} <- File.read("/proc/#{os_pid}/stat"),
         {:ok, group_pid} <- process_group_pid(stat) do
      if group_pid == os_pid do
        {:ok, os_pid}
      else
        probe_child_group_leader(os_pid)
      end
    else
      _ -> :error
    end
  end

  defp probe_child_group_leader(os_pid) do
    with child when is_integer(child) <- session_child_pid(os_pid),
         true <- child != os_pid,
         {:ok, stat} <- File.read("/proc/#{child}/stat"),
         {:ok, ^child} <- process_group_pid(stat) do
      {:ok, child}
    else
      _ -> :error
    end
  end

  defp process_group_pid(stat) do
    with [{delimiter, 2} | _] <- stat |> :binary.matches(") ") |> Enum.reverse(),
         fields <- binary_part(stat, delimiter + 2, byte_size(stat) - delimiter - 2),
         [_state, _parent, group | _rest] <- String.split(fields),
         {group_pid, ""} <- Integer.parse(group) do
      {:ok, group_pid}
    else
      _ -> :error
    end
  end
end
