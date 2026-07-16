defmodule Rekindle.Toolchain.Helper do
  @moduledoc false

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

  @spec compatibility() :: map()
  def compatibility, do: @compatibility

  @spec run_web(Path.t(), map(), Web.t(), keyword()) ::
          {:ok, map(), [map()]} | {:error, atom()}
  def run_web(executable, operation, %Web{} = state, options \\ []) do
    with {:ok, port, buffer} <- start(executable, "web-v1", options),
         :ok <- send_frame(port, operation),
         result <- receive_web(port, buffer, operation, state, [], deadline(options)) do
      result
    end
  end

  @spec run_exec(Path.t(), map(), Exec.t(), keyword()) ::
          {:ok, map(), binary(), binary()} | {:error, atom()}
  def run_exec(executable, spawn, %Exec{} = state, options \\ []) do
    with {:ok, port, buffer} <- start(executable, "exec-v1", options),
         :ok <- send_frame(port, spawn) do
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
  end

  defp start(executable, mode, options) do
    with {:ok, executable} <- Executable.qualify(executable),
         {:ok, port} <-
           Executable.open(executable, [mode], Keyword.put(options, :stderr_to_stdout, false)) do
      host = Installer.host() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      hello = Handshake.hello(mode, @compatibility, host)

      with :ok <- send_frame(port, hello),
           {:ok, response, <<>>} <- receive_one(port, <<>>, deadline(options)),
           :ok <- Handshake.admit_response(response, hello) do
        {:ok, port, <<>>}
      else
        _ ->
          close(port)
          {:error, :helper_protocol}
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
        case Exec.accept(state, header, payload) do
          {:ok, state} ->
            hook_called? =
              run_started_hook(started_hook, hook_called?, port, header, state)

            stdout = if header["type"] == "stdout", do: stdout <> payload, else: stdout
            stderr = if header["type"] == "stderr", do: stderr <> payload, else: stderr

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

          {:terminal, terminal, _state} ->
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
      {^port, {:exit_status, 0}} -> result.()
      {^port, {:data, _extra}} -> {:error, :post_terminal_frame}
      {^port, {:exit_status, _status}} -> {:error, :helper_protocol}
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
  end

  defp deadline(options),
    do: monotonic_ms() + Keyword.get(options, :timeout_ms, 30_000)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
