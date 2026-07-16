defmodule Rekindle.Toolchain.Exec do
  @moduledoc false

  alias Rekindle.Toolchain.Frame

  @cancel_reasons ~w[obsolete timeout shutdown caller]
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/

  defstruct request_id: nil,
            phase: :awaiting_started,
            output_bytes_per_stream: 16_777_216,
            pid: nil,
            process_group: nil,
            stdout_sequence: 0,
            stderr_sequence: 0,
            stdout_eof?: false,
            stderr_eof?: false,
            stdout_bytes: 0,
            stderr_bytes: 0,
            terminal: nil

  @type t :: %__MODULE__{}

  @spec spawn_request(keyword()) :: {:ok, map(), t()} | {:error, atom()}
  def spawn_request(options) do
    request_id = Keyword.get_lazy(options, :request_id, &random_id/0)
    executable = Keyword.get(options, :executable)
    argv = Keyword.get(options, :argv, [])
    cwd = Keyword.get(options, :cwd)
    env_mode = Keyword.get(options, :env_mode, :replace)
    env_set = Keyword.get(options, :env_set, [])
    env_unset = Keyword.get(options, :env_unset, [])
    terminate_grace = Keyword.get(options, :terminate_grace_ms, 3_000)
    kill_grace = Keyword.get(options, :kill_grace_ms, 2_000)
    output_bytes = Keyword.get(options, :output_bytes_per_stream, 16_777_216)

    with :ok <- request_id(request_id),
         :ok <- absolute(executable),
         :ok <- absolute(cwd),
         :ok <- strings(argv),
         true <- env_mode in [:inherit, :replace],
         {:ok, env_set} <- env_set(env_set),
         {:ok, env_unset} <- env_unset(env_unset),
         true <- MapSet.disjoint?(MapSet.new(env_set, &elem(&1, 0)), MapSet.new(env_unset)),
         true <- integer_between?(terminate_grace, 0, 30_000),
         true <- integer_between?(kill_grace, 100, 30_000),
         true <- integer_between?(output_bytes, 1_048_576, 268_435_456) do
      header = %{
        "v" => 1,
        "type" => "spawn",
        "request_id" => request_id,
        "payload_len" => 0,
        "executable" => %{"kind" => "path", "value" => executable},
        "argv" => argv,
        "cwd" => cwd,
        "env_mode" => Atom.to_string(env_mode),
        "env_set" => Enum.map(env_set, fn {key, value} -> [key, value] end),
        "env_unset" => env_unset,
        "terminate_grace_ms" => terminate_grace,
        "kill_grace_ms" => kill_grace
      }

      {:ok, header, %__MODULE__{request_id: request_id, output_bytes_per_stream: output_bytes}}
    else
      _ -> {:error, :invalid_spawn}
    end
  end

  @spec cancel(t(), atom()) :: {:ok, map()} | {:error, atom()}
  def cancel(%__MODULE__{terminal: nil, request_id: request_id}, reason)
      when is_atom(reason) do
    reason = Atom.to_string(reason)

    if reason in @cancel_reasons do
      {:ok,
       %{
         "v" => 1,
         "type" => "cancel",
         "request_id" => request_id,
         "payload_len" => 0,
         "reason" => reason
       }}
    else
      {:error, :invalid_cancel}
    end
  end

  def cancel(_state, _reason), do: {:error, :terminal_session}

  @spec accept(t(), map(), binary()) :: {:ok, t()} | {:terminal, map(), t()} | {:error, atom()}
  def accept(%__MODULE__{terminal: terminal}, _header, _payload) when not is_nil(terminal),
    do: {:error, :post_terminal_frame}

  def accept(state, header, payload) when is_map(header) and is_binary(payload) do
    with :ok <- same_request(state, header),
         true <- header["payload_len"] == byte_size(payload) do
      accept_type(state, header, payload)
    else
      _ -> {:error, :invalid_exec_frame}
    end
  end

  defp accept_type(
         %__MODULE__{phase: :awaiting_started} = state,
         %{"type" => "started"} = header,
         <<>>
       ) do
    if exact_keys?(header, ~w[v type request_id payload_len pid process_group]) and
         positive(header["pid"]) and positive(header["process_group"]) do
      {:ok,
       %{state | phase: :streaming, pid: header["pid"], process_group: header["process_group"]}}
    else
      {:error, :invalid_started}
    end
  end

  defp accept_type(
         %__MODULE__{phase: :awaiting_started} = state,
         %{"type" => "exit"} = header,
         <<>>
       ) do
    terminal(state, header, spawn_failed?: true)
  end

  defp accept_type(
         %__MODULE__{phase: :streaming} = state,
         %{"type" => type} = header,
         payload
       )
       when type in ["stdout", "stderr"] do
    stream(state, header, payload)
  end

  defp accept_type(
         %__MODULE__{phase: :streaming} = state,
         %{"type" => "exit"} = header,
         <<>>
       ) do
    terminal(state, header, spawn_failed?: false)
  end

  defp accept_type(_state, _header, _payload), do: {:error, :unexpected_exec_frame}

  defp stream(state, header, payload) do
    stream = header["type"]
    sequence_key = if stream == "stdout", do: :stdout_sequence, else: :stderr_sequence
    eof_key = if stream == "stdout", do: :stdout_eof?, else: :stderr_eof?
    bytes_key = if stream == "stdout", do: :stdout_bytes, else: :stderr_bytes

    cond do
      not exact_keys?(header, ~w[v type request_id payload_len sequence eof]) ->
        {:error, :invalid_stream_frame}

      Map.fetch!(state, eof_key) ->
        {:error, :stream_after_eof}

      header["sequence"] != Map.fetch!(state, sequence_key) ->
        {:error, :stream_sequence}

      not is_boolean(header["eof"]) ->
        {:error, :invalid_stream_frame}

      true ->
        {:ok,
         state
         |> Map.put(sequence_key, Map.fetch!(state, sequence_key) + 1)
         |> Map.put(eof_key, header["eof"])
         |> Map.put(bytes_key, Map.fetch!(state, bytes_key) + byte_size(payload))}
    end
  end

  defp terminal(state, header, spawn_failed?: spawn_failed?) do
    required =
      ~w[v type request_id payload_len outcome code signal cleanup stdout_bytes stderr_bytes discarded_stdout discarded_stderr]

    outcome = header["outcome"]

    cond do
      not exact_keys?(header, required) ->
        {:error, :invalid_exit}

      outcome not in ~w[exited signaled spawn_failed] ->
        {:error, :invalid_exit}

      spawn_failed? != (outcome == "spawn_failed") ->
        {:error, :invalid_exit_order}

      not spawn_failed? and not (state.stdout_eof? and state.stderr_eof?) ->
        {:error, :missing_stream_eof}

      outcome == "exited" and (not is_integer(header["code"]) or not is_nil(header["signal"])) ->
        {:error, :invalid_exit}

      outcome == "signaled" and (not is_integer(header["signal"]) or not is_nil(header["code"])) ->
        {:error, :invalid_exit}

      outcome == "spawn_failed" and (not is_nil(header["code"]) or not is_nil(header["signal"])) ->
        {:error, :invalid_exit}

      header["cleanup"] not in ~w[confirmed uncertain] ->
        {:error, :invalid_exit}

      header["stdout_bytes"] != state.stdout_bytes or header["stderr_bytes"] != state.stderr_bytes ->
        {:error, :byte_count_mismatch}

      not nonnegative(header["discarded_stdout"]) or not nonnegative(header["discarded_stderr"]) ->
        {:error, :invalid_exit}

      true ->
        result = %{
          outcome: decode_outcome(outcome),
          code: header["code"],
          signal: header["signal"],
          cleanup: decode_cleanup(header["cleanup"]),
          stdout_bytes: header["stdout_bytes"],
          stderr_bytes: header["stderr_bytes"],
          discarded_stdout: header["discarded_stdout"],
          discarded_stderr: header["discarded_stderr"]
        }

        {:terminal, result, %{state | phase: :terminal, terminal: result}}
    end
  end

  defp decode_outcome("exited"), do: :exited
  defp decode_outcome("signaled"), do: :signaled
  defp decode_outcome("spawn_failed"), do: :spawn_failed

  defp decode_cleanup("confirmed"), do: :confirmed
  defp decode_cleanup("uncertain"), do: :uncertain

  @spec encode(map()) :: {:ok, binary()} | {:error, atom()}
  def encode(header), do: Frame.encode(header)

  defp same_request(state, header) do
    if header["request_id"] == state.request_id and header["v"] == 1,
      do: :ok,
      else: {:error, :request_mismatch}
  end

  defp request_id(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{32}\z/, value), do: :ok, else: {:error, :request_id}
  end

  defp request_id(_), do: {:error, :request_id}

  defp absolute(value) when is_binary(value) do
    if Path.type(value) == :absolute and String.valid?(value) and
         not String.contains?(value, <<0>>), do: :ok, else: {:error, :path}
  end

  defp absolute(_), do: {:error, :path}

  defp strings(values) when is_list(values) do
    if proper_list?(values) and
         Enum.all?(
           values,
           &(is_binary(&1) and String.valid?(&1) and not String.contains?(&1, <<0>>))
         ), do: :ok, else: {:error, :strings}
  end

  defp strings(_), do: {:error, :strings}

  defp env_set(values) when is_list(values) do
    with true <- proper_list?(values),
         true <-
           Enum.all?(values, fn
             {key, value} ->
               valid_env?(key) and is_binary(value) and String.valid?(value) and
                 not String.contains?(value, <<0>>)

             _malformed ->
               false
           end),
         true <- unique?(Enum.map(values, &elem(&1, 0))) do
      {:ok, Enum.sort_by(values, &elem(&1, 0))}
    else
      _ -> {:error, :environment}
    end
  end

  defp env_set(_), do: {:error, :environment}

  defp env_unset(values) when is_list(values) do
    if proper_list?(values) and Enum.all?(values, &valid_env?/1) and unique?(values),
      do: {:ok, Enum.sort(values)},
      else: {:error, :environment}
  end

  defp env_unset(_), do: {:error, :environment}

  defp valid_env?(value), do: is_binary(value) and Regex.match?(@env_name, value)
  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_value), do: false
  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(values))

  defp integer_between?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp positive(value), do: is_integer(value) and value > 0
  defp nonnegative(value), do: is_integer(value) and value >= 0
  defp exact_keys?(map, keys), do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
