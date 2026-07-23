defmodule Rekindle.Desktop.Development do
  @moduledoc false

  use GenServer

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
       readiness: Keyword.get(options, :readiness, 300),
       notify: Keyword.get(options, :notify),
       process_options: Keyword.get(options, :process_options, []),
       current: nil,
       candidate: nil
     }}
  end

  @impl GenServer
  def handle_cast({:replace, result}, state) do
    {:noreply, launch(state, result)}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       current: process_status(state.current),
       candidate: process_status(state.candidate)
     }, state}
  end

  @impl GenServer
  def handle_info(
        {Rekindle.Development.Builder, :desktop, {:ok, %Result{} = result}},
        state
      ) do
    {:noreply, launch(state, result)}
  end

  def handle_info({Rekindle.Development.Builder, :desktop, {:error, _error}}, state) do
    {:noreply, state}
  end

  def handle_info({:ready, reference}, %{candidate: %{reference: reference}} = state) do
    candidate = state.candidate

    if Process.alive?(candidate.pid) and MuonTrap.Daemon.os_pid(candidate.pid) != :error do
      case write_marker(state.root, candidate.result) do
        :ok ->
          stop(state.supervisor, state.current)
          notify(state.notify, {:ready, candidate.result})
          {:noreply, %{state | current: candidate, candidate: nil}}

        {:error, error} ->
          stop(state.supervisor, candidate)
          notify(state.notify, {:error, error})
          {:noreply, %{state | candidate: nil}}
      end
    else
      error = Error.new(:readiness, "desktop process exited before it became ready")
      notify(state.notify, {:error, error})
      {:noreply, %{state | candidate: nil}}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    cond do
      state.candidate && state.candidate.reference == reference ->
        Process.cancel_timer(state.candidate.timer)

        error =
          Error.new(
            :readiness,
            "desktop process exited before it became ready: #{inspect(reason)}"
          )

        notify(state.notify, {:error, error})
        {:noreply, %{state | candidate: nil}}

      state.current && state.current.reference == reference ->
        {:noreply, %{state | current: nil}}

      true ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    stop(state.supervisor, state.candidate)
    stop(state.supervisor, state.current)
  end

  defp launch(%{current: %{result: %{metadata: %{generation: generation}}}} = state, %{
         metadata: %{generation: generation}
       }) do
    stop(state.supervisor, state.candidate)
    %{state | candidate: nil}
  end

  defp launch(state, result) do
    stop(state.supervisor, state.candidate)

    with :ok <- validate(result),
         {:ok, pid} <- start_process(state, result) do
      reference = Process.monitor(pid)
      timer = Process.send_after(self(), {:ready, reference}, state.readiness)
      candidate = %{pid: pid, reference: reference, timer: timer, result: result}
      %{state | candidate: candidate}
    else
      {:error, %Error{} = error} ->
        notify(state.notify, {:error, error})
        %{state | candidate: nil}

      {:error, reason} ->
        error = Error.new(:start_failed, "desktop process could not start: #{inspect(reason)}")
        notify(state.notify, {:error, error})
        %{state | candidate: nil}
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

  defp validate(%Result{target: :desktop, profile: :dev, metadata: metadata} = result) do
    with manifest_path when is_binary(manifest_path) <- metadata[:manifest],
         {:ok, contents} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(contents),
         true <- manifest["generation"] == metadata[:generation],
         true <- manifest["target"] == metadata[:rust_target],
         true <- is_binary(manifest["executable"]),
         true <- Path.join(Path.dirname(manifest_path), manifest["executable"]) == result.artifact,
         :ok <- Manifest.validate(Path.dirname(manifest_path), manifest) do
      :ok
    else
      _error -> {:error, Error.new(:invalid_manifest, "desktop build result is not launchable")}
    end
  end

  defp validate(_result),
    do: {:error, Error.new(:invalid_result, "expected a desktop development build result")}

  defp write_marker(root, result) do
    directory = Path.join([root, ".rekindle", "dev"])
    destination = Path.join(directory, "desktop-last-running.json")
    temporary = destination <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    marker =
      Jason.encode!(%{
        "generation" => result.metadata.generation,
        "target" => result.metadata.rust_target,
        "manifest" => Path.relative_to(result.metadata.manifest, directory)
      })

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary, marker),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)

        {:error,
         Error.new(
           :marker_write,
           "desktop launch state could not be updated: #{:file.format_error(reason)}"
         )}
    end
  end

  defp stop(_supervisor, nil), do: :ok

  defp stop(supervisor, process) do
    if process.timer, do: Process.cancel_timer(process.timer)
    Process.demonitor(process.reference, [:flush])

    case DynamicSupervisor.terminate_child(supervisor, process.pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp process_status(nil), do: nil

  defp process_status(process) do
    %{pid: process.pid, result: process.result}
  end

  defp notify(nil, _message), do: :ok
  defp notify(pid, message), do: send(pid, {__MODULE__, message})
end
