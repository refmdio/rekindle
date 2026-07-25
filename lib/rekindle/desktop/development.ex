defmodule Rekindle.Desktop.Development do
  @moduledoc false

  use GenServer

  require Logger

  alias Rekindle.Build.Result
  alias Rekindle.Development.Cleanup
  alias Rekindle.Desktop.{Error, Manifest}
  alias Rekindle.OwnedPath
  alias Rekindle.Publication

  @generation ~r/\A[0-9a-f]{64}\z/

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
    Process.flag(:trap_exit, true)

    root = options |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()

    {:ok,
     %{
       root: root,
       supervisor: Keyword.fetch!(options, :supervisor),
       readiness: Keyword.get(options, :readiness, 300),
       notify: Keyword.get(options, :notify),
       process_options: Keyword.get(options, :process_options, []),
       retained: locked_retained(root),
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

  def handle_info({Rekindle.Development.Builder, :desktop, {:error, error}}, state) do
    notify(state.notify, {:error, error})
    {:noreply, state}
  end

  def handle_info({:ready, reference}, %{candidate: %{reference: reference}} = state) do
    candidate = state.candidate

    if running?(candidate.pid) do
      case retain_running(state.root, candidate.result) do
        :ok ->
          notify(state.notify, {:ready, candidate.result})
          {:noreply, %{state | retained: candidate.result, current: candidate, candidate: nil}}

        {:error, error} ->
          {:noreply, reject_candidate(state, error)}
      end
    else
      error = Error.new(:readiness, "desktop process exited before it became ready")
      {:noreply, reject_candidate(state, error)}
    end
  end

  def handle_info({:ready, _reference}, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    cond do
      state.candidate && state.candidate.reference == reference ->
        Process.cancel_timer(state.candidate.timer)

        error =
          Error.new(
            :readiness,
            "desktop process exited before it became ready: #{inspect(reason)}"
          )

        {:noreply, reject_candidate(state, error)}

      state.current && state.current.reference == reference ->
        notify(state.notify, {:exited, state.current.result, reason})
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
    discard_candidate(state)
    %{state | candidate: nil}
  end

  defp launch(state, result) do
    case validate(state.root, result) do
      :ok ->
        fallback = state.retained
        discard_candidate(state)
        stop(state.supervisor, state.current)

        state
        |> Map.merge(%{current: nil, candidate: nil})
        |> start_candidate(result, fallback, false)

      {:error, %Error{} = error} ->
        cleanup_rejected(state, result)
        notify(state.notify, {:error, error})
        state
    end
  end

  defp start_candidate(state, result, fallback, rollback?) do
    case start_process(state, result) do
      {:ok, pid} ->
        reference = Process.monitor(pid)
        timer = Process.send_after(self(), {:ready, reference}, state.readiness)

        candidate = %{
          pid: pid,
          reference: reference,
          timer: timer,
          result: result,
          fallback: fallback,
          rollback?: rollback?
        }

        %{state | candidate: candidate}

      {:error, reason} ->
        error = Error.new(:start_failed, "desktop process could not start: #{inspect(reason)}")
        cleanup_rejected(state, result)
        notify(state.notify, {:error, error})

        maybe_rollback(%{state | candidate: nil}, fallback, rollback?)
    end
  end

  defp reject_candidate(state, error) do
    candidate = state.candidate
    stop(state.supervisor, candidate)
    cleanup_rejected(state, candidate.result)
    notify(state.notify, {:error, error})
    maybe_rollback(%{state | candidate: nil}, candidate.fallback, candidate.rollback?)
  end

  defp discard_candidate(%{candidate: nil}), do: :ok

  defp discard_candidate(state) do
    stop(state.supervisor, state.candidate)
    cleanup_rejected(state, state.candidate.result)
  end

  defp maybe_rollback(state, nil, _rollback?), do: state
  defp maybe_rollback(state, _fallback, true), do: state

  defp maybe_rollback(state, fallback, false) do
    start_candidate(state, fallback, nil, true)
  end

  defp cleanup_rejected(state, result) do
    Cleanup.desktop(state.root, result)
  end

  defp running?(pid) do
    Process.alive?(pid) and daemon_running?(pid)
  end

  defp daemon_running?(pid) do
    MuonTrap.Daemon.os_pid(pid) != :error
  catch
    :exit, _reason -> false
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
         %Result{target: :desktop, profile: :dev, metadata: metadata} = result
       ) do
    with manifest_path when is_binary(manifest_path) <- metadata[:manifest],
         :ok <- OwnedPath.validate_parent(root, manifest_path),
         {:ok, manifest} <- Manifest.read(Path.dirname(manifest_path)),
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

  defp validate(_root, _result),
    do: {:error, Error.new(:invalid_result, "expected a desktop development build result")}

  defp load_retained(root) do
    directory = Path.join([root, ".rekindle", "dev"])
    marker_path = Path.join(directory, "desktop-last-running.json")

    with :ok <- OwnedPath.validate_directory(root, directory),
         {:ok, contents} <- OwnedPath.read_file(root, marker_path),
         {:ok,
          %{
            "generation" => generation,
            "target" => target,
            "manifest" => relative_manifest
          }} <- Jason.decode(contents),
         true <- is_binary(generation) and Regex.match?(@generation, generation),
         true <- is_binary(target) and Path.basename(target) == target,
         expected = Path.join(["desktop", target, generation, "manifest.json"]),
         true <- relative_manifest == expected,
         manifest_path = Path.join(directory, relative_manifest),
         {:ok, manifest} <- Manifest.read(Path.dirname(manifest_path)),
         true <- manifest["generation"] == generation,
         true <- manifest["target"] == target,
         :ok <- Manifest.validate(Path.dirname(manifest_path), manifest) do
      %Result{
        target: :desktop,
        profile: :dev,
        artifact: Path.join(Path.dirname(manifest_path), manifest["executable"]),
        metadata: %{
          generation: generation,
          manifest: manifest_path,
          rust_target: target
        }
      }
    else
      _error -> nil
    end
  end

  defp locked_retained(root) do
    case Cleanup.with_desktop_lock(root, fn -> load_retained(root) end) do
      %Result{} = result -> result
      _error -> nil
    end
  end

  defp retain_running(root, result) do
    case Cleanup.with_desktop_lock(root, fn ->
           with :ok <- validate(root, result),
                :ok <- write_marker(root, result) do
             Cleanup.desktop_locked(root, result, result.metadata.generation)
           end
         end) do
      {:error, {:publication_lock, reason}} ->
        marker_error(reason)

      result ->
        result
    end
  end

  defp write_marker(root, result) do
    directory = Path.join([root, ".rekindle", "dev"])
    destination = Path.join(directory, "desktop-last-running.json")

    marker =
      Jason.encode!(%{
        "generation" => result.metadata.generation,
        "target" => result.metadata.rust_target,
        "manifest" => Path.relative_to(result.metadata.manifest, directory)
      })

    with :ok <- OwnedPath.ensure_directory(root, directory),
         {:ok, temporary} <-
           Publication.temporary_file(directory, ".tmp-desktop-last-running-") do
      publish_marker(root, temporary, destination, marker)
    else
      {:error, reason} -> marker_error(reason)
    end
  end

  defp publish_marker(root, temporary, destination, marker) do
    with :ok <- File.write(temporary, marker),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      {:error, reason} ->
        OwnedPath.remove_file(root, temporary)
        marker_error(reason)
    end
  end

  defp marker_error(reason) do
    {:error,
     Error.new(
       :marker_write,
       "desktop launch state could not be updated: #{OwnedPath.format_error(reason)}"
     )}
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

  defp notify(notify, {:error, error} = message) do
    Logger.error("desktop development failed: #{error_message(error)}")
    send_notification(notify, message)
  end

  defp notify(notify, {:exited, result, reason} = message) do
    Logger.error(
      "desktop development process exited for generation #{result.metadata.generation}: " <>
        inspect(reason)
    )

    send_notification(notify, message)
  end

  defp notify(notify, message), do: send_notification(notify, message)

  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)

  defp send_notification(nil, _message), do: :ok
  defp send_notification(pid, message), do: send(pid, {__MODULE__, message})
end
