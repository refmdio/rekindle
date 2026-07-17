defmodule Rekindle.Toolchain.Helper do
  @moduledoc false

  alias Rekindle.Failure
  alias Rekindle.Toolchain.{Exec, Executable, Frame, Handshake, Installer, Web}

  @compatibility %{
    "helper_version" => "0.1.0",
    "toolframe" => 1,
    "exec_protocol" => 1,
    "web_protocol" => 1,
    "wasm_bindgen_schema" => "0.2.121",
    "web_manifest" => 1,
    "native_manifest" => 1
  }
  @verification_executables ["/usr/bin/true", "/bin/true"]

  @spec compatibility() :: map()
  def compatibility, do: @compatibility

  @spec verify(Path.t(), keyword()) :: :ok | {:error, Failure.t()}
  def verify(executable, options \\ []) do
    with {:ok, verification_executable} <- verification_executable(),
         {:ok, spawn, state} <-
           Exec.spawn_request(
             executable: verification_executable.path,
             argv: [],
             cwd: "/",
             env_mode: :replace,
             env_set: [],
             env_unset: [],
             terminate_grace_ms: 0,
             kill_grace_ms: 100,
             output_bytes_per_stream: 1_048_576
           ),
         {:ok,
          %{
            outcome: :exited,
            code: 0,
            signal: nil,
            cleanup: :confirmed,
            stdout_bytes: 0,
            stderr_bytes: 0,
            discarded_stdout: 0,
            discarded_stderr: 0
          }, <<>>, <<>>} <-
           run_exec(
             executable,
             spawn,
             state,
             options
             |> Keyword.put(:stderr_to_stdout, true)
             |> Keyword.put(:cleanup_timeout_ms, Keyword.get(options, :timeout_ms, 30_000))
           ) do
      :ok
    else
      _ -> verification_failure()
    end
  rescue
    _ -> verification_failure()
  catch
    _, _ -> verification_failure()
  end

  @spec run_web(Path.t(), map(), Web.t(), keyword()) ::
          {:ok, map(), [map()]} | {:error, atom()}
  def run_web(executable, operation, %Web{} = state, options \\ []) do
    case Web.admit_operation(state, operation) do
      {:ok, admitted_state} ->
        run_admitted_web(executable, operation, admitted_state, options)

      {:error, _reason} ->
        Web.release(state)
        {:error, :helper_protocol}
    end
  end

  defp run_admitted_web(executable, operation, state, options) do
    try do
      with {:ok, port, buffer} <- start(executable, "web-v1", options) do
        try do
          case send_frame(port, operation) do
            :ok -> receive_web(port, buffer, operation, state, [], deadline(options))
            {:error, reason} -> {:error, reason}
          end
        after
          close(port)
        end
      end
    after
      Web.release(state)
    end
  end

  @spec run_exec(Path.t(), map(), Exec.t(), keyword()) ::
          {:ok, map(), binary(), binary()} | {:error, atom()}
  def run_exec(executable, spawn, %Exec{} = state, options \\ []) do
    with {:ok, port, buffer} <- start(executable, "exec-v1", options) do
      try do
        with :ok <- send_frame(port, spawn) do
          receive_exec(
            port,
            buffer,
            state,
            <<>>,
            <<>>,
            deadline(options),
            false,
            Keyword.get(options, :cleanup_timeout_ms, 5_000),
            Keyword.get(options, :started_hook),
            false
          )
        end
      after
        close(port)
      end
    end
  end

  defp start(executable, mode, options) do
    with {:ok, executable} <- Executable.qualify(executable),
         {:ok, port, handle} <-
           Executable.open(executable, [mode], Keyword.put_new(options, :stderr_to_stdout, false)) do
      host = Installer.host() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      hello = Handshake.hello(mode, @compatibility, host)

      try do
        with :ok <- send_frame(port, hello),
             {:ok, response, <<>>} <- receive_one(port, <<>>, deadline(options)),
             :ok <- Handshake.admit_response(response, hello),
             :ok <- Executable.revalidate(executable),
             :ok <- invoke_port_hook(options, :after_handshake, port) do
          {:ok, port, <<>>}
        else
          _ ->
            close(port)
            {:error, :helper_protocol}
        end
      rescue
        _error ->
          close(port)
          {:error, :helper_protocol}
      catch
        _, _ ->
          close(port)
          {:error, :helper_protocol}
      after
        Executable.release(handle)
      end
    else
      _ -> {:error, :helper_missing}
    end
  end

  defp receive_web(port, buffer, operation, state, diagnostics, deadline) do
    with {:ok, header, remaining} <- receive_one(port, buffer, deadline) do
      case Web.accept(state, header) do
        {:ok, state, diagnostic} ->
          receive_web(
            port,
            remaining,
            operation,
            state,
            diagnostics ++ [diagnostic],
            deadline
          )

        {:terminal, terminal, _state} ->
          with :ok <- revalidate_web_result(operation, terminal) do
            finish(port, remaining, deadline, fn -> {:ok, terminal, diagnostics} end)
          else
            _ ->
              close(port)
              {:error, :helper_protocol}
          end

        {:error, _reason} ->
          close(port)
          {:error, :helper_protocol}
      end
    else
      _ ->
        close(port)
        {:error, :helper_protocol}
    end
  end

  defp receive_exec(
         port,
         buffer,
         state,
         stdout,
         stderr,
         deadline,
         cancel_sent?,
         cleanup_timeout,
         started_hook,
         hook_called?
       ) do
    case next_frame(port, buffer, deadline) do
      {:ok, header, payload, remaining} ->
        captured = captured_payload(state, header, payload)

        case Exec.accept(state, header, payload) do
          {:ok, state} ->
            hook_called? =
              run_started_hook(started_hook, hook_called?, port, header, state)

            stdout = if header["type"] == "stdout", do: stdout <> captured, else: stdout
            stderr = if header["type"] == "stderr", do: stderr <> captured, else: stderr

            receive_exec(
              port,
              remaining,
              state,
              stdout,
              stderr,
              deadline,
              cancel_sent?,
              cleanup_timeout,
              started_hook,
              hook_called?
            )

          {:terminal, terminal, state} ->
            terminal = captured_terminal(terminal, state, stdout, stderr)

            finish(port, remaining, monotonic_ms() + cleanup_timeout, fn ->
              {:ok, terminal, stdout, stderr}
            end)

          {:error, reason} ->
            close(port)
            {:error, reason}
        end

      {:error, :timeout} when not cancel_sent? ->
        with {:ok, cancel} <- Exec.cancel(state, :timeout),
             :ok <- send_frame(port, cancel) do
          receive_exec(
            port,
            <<>>,
            state,
            stdout,
            stderr,
            monotonic_ms() + cleanup_timeout,
            true,
            cleanup_timeout,
            started_hook,
            hook_called?
          )
        else
          _ ->
            close(port)
            {:error, :helper_protocol}
        end

      _other ->
        close(port)
        {:error, :helper_protocol}
    end
  end

  defp run_started_hook(hook, false, port, %{"type" => "started"}, state)
       when is_function(hook, 2) do
    hook.(port, state)
    true
  end

  defp run_started_hook(_hook, called?, _port, _header, _state), do: called?

  defp captured_payload(state, %{"type" => "stdout"}, payload),
    do: retain(payload, state.stdout_bytes, state.output_bytes_per_stream)

  defp captured_payload(state, %{"type" => "stderr"}, payload),
    do: retain(payload, state.stderr_bytes, state.output_bytes_per_stream)

  defp captured_payload(_state, _header, _payload), do: <<>>

  defp retain(payload, received, limit) do
    kept = min(byte_size(payload), max(limit - received, 0))
    if kept == 0, do: <<>>, else: binary_part(payload, 0, kept)
  end

  defp captured_terminal(terminal, state, stdout, stderr) do
    stdout_bytes = byte_size(stdout)
    stderr_bytes = byte_size(stderr)

    %{
      terminal
      | stdout_bytes: stdout_bytes,
        stderr_bytes: stderr_bytes,
        discarded_stdout: terminal.discarded_stdout + max(state.stdout_bytes - stdout_bytes, 0),
        discarded_stderr: terminal.discarded_stderr + max(state.stderr_bytes - stderr_bytes, 0)
    }
  end

  defp revalidate_web_result(_operation, %{"type" => "operation_error"}), do: :ok

  defp revalidate_web_result(
         %{"op" => op, "output_root" => root},
         %{"op" => op, "files" => files} = terminal
       )
       when op in ["bindgen_web", "package_web"] do
    with :ok <- Web.revalidate_files(root, files),
         :ok <- maybe_revalidate_manifest(op, root, terminal) do
      :ok
    end
  end

  defp revalidate_web_result(
         %{"op" => "verify_web", "artifact_root" => root},
         %{"op" => "verify_web"} = terminal
       ),
       do: Web.revalidate_manifest(root, terminal)

  defp revalidate_web_result(_operation, _terminal), do: {:error, :invalid_result}

  defp maybe_revalidate_manifest("package_web", root, terminal),
    do: Web.revalidate_manifest(root, terminal)

  defp maybe_revalidate_manifest("bindgen_web", _root, _terminal), do: :ok

  defp finish(port, <<>>, deadline, result) do
    receive do
      {^port, {:exit_status, 0}} ->
        close(port)
        result.()

      {^port, {:data, _extra}} ->
        close(port)
        {:error, :post_terminal_frame}

      {^port, {:exit_status, _status}} ->
        close(port)
        {:error, :helper_protocol}
    after
      max(deadline - monotonic_ms(), 0) ->
        close(port)
        {:error, :helper_timeout}
    end
  end

  defp finish(port, _remaining, _deadline, _result) do
    close(port)
    {:error, :post_terminal_frame}
  end

  defp receive_one(port, buffer, deadline) do
    case next_frame(port, buffer, deadline) do
      {:ok, header, <<>>, remaining} -> {:ok, header, remaining}
      _ -> {:error, :helper_protocol}
    end
  end

  defp next_frame(port, buffer, deadline) do
    case Frame.decode(buffer) do
      {:ok, header, payload, remaining} ->
        {:ok, header, payload, remaining}

      {:more, _needed} ->
        receive do
          {^port, {:data, bytes}} -> next_frame(port, buffer <> bytes, deadline)
          {^port, {:exit_status, _status}} -> {:error, :helper_exit}
        after
          max(deadline - monotonic_ms(), 0) -> {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_frame(port, header) do
    with {:ok, encoded} <- Frame.encode(header),
         true <- Port.command(port, encoded) do
      :ok
    else
      _ -> {:error, :helper_io}
    end
  rescue
    ArgumentError -> {:error, :helper_io}
  end

  defp invoke_port_hook(options, name, port) do
    case Keyword.get(options, name) do
      nil -> :ok
      hook when is_function(hook, 1) -> hook.(port)
      _other -> {:error, :invalid_hook}
    end
  end

  defp deadline(options),
    do: monotonic_ms() + Keyword.get(options, :timeout_ms, 30_000)

  defp verification_executable do
    Enum.find_value(
      @verification_executables,
      {:error, :verification_executable_missing},
      fn path ->
        case Executable.qualify(path) do
          {:ok, executable} -> {:ok, executable}
          {:error, _reason} -> false
        end
      end
    )
  end

  defp verification_failure do
    {:error,
     Failure.new!(
       target: nil,
       stage: :compatibility,
       code: :helper_protocol_mismatch,
       message: "installed helper failed compatibility negotiation"
     )}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
