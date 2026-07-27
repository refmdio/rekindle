defmodule Rekindle.Desktop.Development do
  @moduledoc false

  use GenServer

  require Logger

  alias Rekindle.Build.Result
  alias Rekindle.Desktop.{Error, Manifest}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @spec replace(GenServer.server(), Result.t()) :: :ok
  def replace(server, %Result{target: :desktop} = result) do
    GenServer.cast(server, {:replace, result})
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl GenServer
  def init(options) do
    {:ok,
     %{
       root: options |> Keyword.get(:project_root, File.cwd!()) |> Path.expand(),
       supervisor: Keyword.fetch!(options, :supervisor),
       notify: Keyword.get(options, :notify),
       process_options: Keyword.get(options, :process_options, []),
       current: nil
     }}
  end

  @impl GenServer
  def handle_cast({:replace, result}, state), do: {:noreply, launch(state, result)}

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, %{current: process_status(state.current)}, state}
  end

  @impl GenServer
  def handle_info(
        {Rekindle.Development.Builder, :desktop, {:ok, %Result{} = result}},
        state
      ) do
    {:noreply, launch(state, result)}
  end

  def handle_info({Rekindle.Development.Builder, :desktop, {:error, error}}, state) do
    notify(state.notify, {:error, error})
    {:noreply, state}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case state.current do
      %{reference: ^reference, result: result} ->
        cleanup(state.root, result)
        notify(state.notify, {:exited, result, reason})
        {:noreply, %{state | current: nil}}

      _other ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    stop(state.supervisor, state.current)
    if state.current, do: cleanup(state.root, state.current.result)
  end

  defp launch(state, result) do
    case validate(state.root, result) do
      :ok ->
        stop(state.supervisor, state.current)
        if state.current, do: cleanup(state.root, state.current.result)

        case start_process(state, result) do
          {:ok, pid} ->
            current = %{pid: pid, reference: Process.monitor(pid), result: result}
            notify(state.notify, {:ready, result})
            %{state | current: current}

          {:error, reason} ->
            cleanup(state.root, result)

            notify(
              state.notify,
              {:error,
               Error.new(:start_failed, "desktop process could not start: #{inspect(reason)}")}
            )

            %{state | current: nil}
        end

      {:error, %Error{} = error} ->
        cleanup(state.root, result)
        notify(state.notify, {:error, error})
        state
    end
  end

  defp start_process(state, result) do
    options =
      Keyword.merge(
        [
          cd: Path.dirname(result.artifact),
          stderr_to_stdout: true,
          log_output: :debug,
          delay_to_sigkill: 500
        ],
        state.process_options
      )

    child =
      Supervisor.child_spec(
        {MuonTrap.Daemon, [result.artifact, [], options]},
        restart: :temporary
      )

    DynamicSupervisor.start_child(state.supervisor, child)
  rescue
    error -> {:error, error}
  end

  defp validate(
         root,
         %Result{target: :desktop, profile: :dev, artifact: artifact, metadata: metadata}
       ) do
    manifest_path = metadata[:manifest]
    development_root = Path.join([root, ".rekindle", "dev", "desktop"])

    with true <- is_binary(manifest_path),
         true <- inside?(manifest_path, development_root),
         {:ok, manifest} <- Manifest.read(Path.dirname(manifest_path)),
         true <- manifest["target"] == metadata[:rust_target],
         true <- Path.join(Path.dirname(manifest_path), manifest["executable"]) == artifact,
         :ok <- Manifest.validate(Path.dirname(manifest_path), manifest) do
      :ok
    else
      _error -> {:error, Error.new(:invalid_manifest, "desktop build result is not launchable")}
    end
  end

  defp validate(_root, _result),
    do: {:error, Error.new(:invalid_result, "expected a desktop development build result")}

  defp stop(_supervisor, nil), do: :ok

  defp stop(supervisor, process) do
    Process.demonitor(process.reference, [:flush])

    case DynamicSupervisor.terminate_child(supervisor, process.pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp cleanup(root, %Result{metadata: %{manifest: manifest}}) do
    directory = Path.dirname(manifest)
    development_root = Path.join([root, ".rekindle", "dev", "desktop"])
    if inside?(directory, development_root), do: File.rm_rf(directory)
    :ok
  end

  defp cleanup(_root, _result), do: :ok

  defp inside?(path, root) do
    expanded = Path.expand(path)
    expanded != root and String.starts_with?(expanded, root <> "/")
  end

  defp process_status(nil), do: nil
  defp process_status(process), do: %{pid: process.pid, result: process.result}

  defp notify(notify, {:error, error} = message) do
    Logger.error("desktop development failed: #{error_message(error)}")
    send_notification(notify, message)
  end

  defp notify(notify, {:exited, _result, :normal} = message) do
    Logger.info("desktop development process exited normally")
    send_notification(notify, message)
  end

  defp notify(notify, {:exited, _result, reason} = message) do
    Logger.error("desktop development process exited: #{inspect(reason)}")
    send_notification(notify, message)
  end

  defp notify(notify, message), do: send_notification(notify, message)

  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)

  defp send_notification(nil, _message), do: :ok
  defp send_notification(pid, message), do: send(pid, {__MODULE__, message})
end
