defmodule Rekindle.ProcessRunner do
  @moduledoc false
  use GenServer

  alias Rekindle.ProcessRunner.Result
  alias Rekindle.Toolchain.Exec
  alias Rekindle.{ExecutionResult, Failure, Redactor}

  defstruct adapter: Rekindle.ProcessRunner.DefaultAdapter,
            jobs: %{},
            monitors: %{},
            admission: :open,
            shutdown_waiters: [],
            shutdown_failures: []

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @spec run(GenServer.server(), keyword()) :: {:ok, reference()} | {:error, Failure.t()}
  def run(server, request), do: GenServer.call(server, {:run, self(), request})

  @spec cancel(GenServer.server(), reference(), :obsolete | :shutdown | :caller) ::
          :ok | {:error, Failure.t()}
  def cancel(server, reference, reason),
    do: GenServer.call(server, {:cancel, self(), reference, reason})

  @spec begin_shutdown(GenServer.server()) :: {:ok, :stopped | reference()}
  def begin_shutdown(server), do: GenServer.call(server, {:begin_shutdown, self()})

  @impl true
  def init(options),
    do:
      {:ok,
       %__MODULE__{adapter: Keyword.get(options, :adapter, Rekindle.ProcessRunner.DefaultAdapter)}}

  @impl true
  def handle_call({:run, caller, request}, _from, %{admission: :open} = state) do
    with {:ok, admitted} <- admit(request),
         {:ok, spawn, exec_state} <- Exec.spawn_request(admitted.spawn) do
      reference = make_ref()
      caller_monitor = Process.monitor(caller)
      parent = self()

      {worker, worker_monitor} =
        spawn_monitor(fn ->
          execute(parent, reference, state.adapter, admitted, spawn, exec_state)
        end)

      timer = Process.send_after(self(), {:runner_timeout, reference}, admitted.build_timeout_ms)

      job = %{
        caller: caller,
        caller_monitor: caller_monitor,
        worker: worker,
        worker_monitor: worker_monitor,
        target: admitted.target,
        build_key: admitted.build_key,
        started_at: System.monotonic_time(:millisecond),
        timer: timer,
        cleanup_timer: nil,
        cleanup_timeout_ms: admitted.cleanup_timeout_ms,
        port: nil,
        exec_state: exec_state,
        cancel_reason: nil,
        cancel_worker: nil
      }

      state = put_job(state, reference, job)
      {:reply, {:ok, reference}, state}
    else
      {:error, %Failure{} = failure} ->
        {:reply, {:error, failure}, state}

      {:error, _reason} ->
        {:reply, failure(:spawn_failed, nil, "Process request is invalid"), state}
    end
  end

  def handle_call({:run, _caller, _request}, _from, state) do
    {:reply, failure(:cancelled, nil, "Process runner is stopping"), state}
  end

  def handle_call({:cancel, caller, reference, reason}, _from, state) do
    case Map.fetch(state.jobs, reference) do
      {:ok, %{caller: ^caller} = job} when reason in [:obsolete, :shutdown, :caller] ->
        {reply, state} = request_cancel(state, reference, job, reason)
        {:reply, reply, state}

      _ ->
        {:reply, failure(:cancelled, nil, "Process job is not owned by the caller"), state}
    end
  end

  def handle_call({:begin_shutdown, _caller}, _from, %{admission: :stopped} = state) do
    {:reply, {:ok, :stopped}, state}
  end

  def handle_call({:begin_shutdown, caller}, _from, state) do
    reference = make_ref()
    state = %{state | admission: :stopping}

    state =
      Enum.reduce(state.jobs, state, fn {job_reference, job}, acc ->
        {_reply, acc} = request_cancel(acc, job_reference, job, :shutdown)
        acc
      end)

    if map_size(state.jobs) == 0 do
      {:reply, {:ok, :stopped}, finish_shutdown(state)}
    else
      waiter = %{pid: caller, reference: reference}
      {:reply, {:ok, reference}, %{state | shutdown_waiters: [waiter | state.shutdown_waiters]}}
    end
  end

  @impl true
  def handle_info({:runner_port, reference, port, exec_state}, state) do
    {:noreply,
     update_job(state, reference, fn job ->
       job = %{job | port: port, exec_state: exec_state}
       maybe_start_cancel(state.adapter, job)
     end)}
  end

  def handle_info({:runner_result, reference, raw_result}, state) do
    case Map.pop(state.jobs, reference) do
      {nil, _jobs} ->
        {:noreply, state}

      {job, jobs} ->
        cleanup_job(job)
        result = map_result(job, raw_result)
        send(job.caller, {:rekindle_process, reference, result})

        state = %{
          state
          | jobs: jobs,
            monitors: drop_monitors(state.monitors, job),
            shutdown_failures: record_shutdown_failure(state, result)
        }

        {:noreply, maybe_finish_shutdown(state)}
    end
  end

  def handle_info({:runner_timeout, reference}, state) do
    case Map.fetch(state.jobs, reference) do
      {:ok, job} ->
        {_reply, state} = request_cancel(state, reference, job, :timeout)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:runner_cleanup_timeout, reference}, state) do
    case Map.pop(state.jobs, reference) do
      {nil, _jobs} ->
        {:noreply, state}

      {job, jobs} ->
        cleanup_job(job)
        Process.exit(job.worker, :kill)

        result =
          failure(
            :cleanup_unconfirmed,
            job.target,
            "Cancelled process cleanup exceeded its deadline"
          )

        send(job.caller, {:rekindle_process, reference, result})

        state = %{
          state
          | jobs: jobs,
            monitors: drop_monitors(state.monitors, job),
            shutdown_failures: record_shutdown_failure(state, result)
        }

        {:noreply, maybe_finish_shutdown(state)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, monitor) do
      {reference, :caller} ->
        case Map.fetch(state.jobs, reference) do
          {:ok, job} ->
            {_reply, state} = request_cancel(state, reference, job, :caller)
            {:noreply, state}

          :error ->
            {:noreply, state}
        end

      {reference, :worker} ->
        case Map.fetch(state.jobs, reference) do
          {:ok, job} ->
            send(self(), {:runner_result, reference, {:error, worker_failure(job)}})
            {:noreply, state}

          :error ->
            {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  defp execute(parent, reference, adapter, admitted, spawn, exec_state) do
    hook = fn port ->
      send(parent, {:runner_port, reference, port, exec_state})
      :ok
    end

    options = [
      timeout_ms: admitted.build_timeout_ms + admitted.cleanup_timeout_ms,
      cleanup_timeout_ms: admitted.cleanup_timeout_ms,
      after_handshake: hook
    ]

    result =
      adapter_module(adapter).run_exec(
        admitted.helper,
        spawn,
        exec_state,
        Keyword.merge(options, adapter_options(adapter))
      )

    send(parent, {:runner_result, reference, result})
  rescue
    _ -> send(parent, {:runner_result, reference, {:error, :helper_protocol}})
  catch
    _, _ -> send(parent, {:runner_result, reference, {:error, :helper_protocol}})
  end

  defp admit(request) when is_list(request) do
    target = Keyword.get(request, :target)
    build_key = Keyword.get(request, :build_key)
    helper = Keyword.get(request, :helper)
    timeout = Keyword.get(request, :build_timeout_ms, 900_000)
    cleanup = Keyword.get(request, :cleanup_timeout_ms, 5_000)

    spawn =
      Keyword.take(request, [
        :executable,
        :argv,
        :cwd,
        :env_mode,
        :env_set,
        :env_unset,
        :terminate_grace_ms,
        :kill_grace_ms,
        :output_bytes_per_stream
      ])

    if target in [:web, :desktop] and sha256?(build_key) and normalized_absolute?(helper) and
         is_integer(timeout) and timeout in 1_000..3_600_000 and is_integer(cleanup) and
         cleanup in 100..30_000 do
      {:ok,
       %{
         target: target,
         build_key: build_key,
         helper: helper,
         build_timeout_ms: timeout,
         cleanup_timeout_ms: cleanup,
         spawn: spawn
       }}
    else
      failure(:spawn_failed, target, "Process request is invalid")
    end
  end

  defp admit(_request), do: failure(:spawn_failed, nil, "Process request is invalid")

  defp request_cancel(state, reference, %{cancel_reason: nil} = job, reason) do
    Process.cancel_timer(job.timer)

    cleanup_timer =
      Process.send_after(
        self(),
        {:runner_cleanup_timeout, reference},
        job.cleanup_timeout_ms
      )

    job = %{job | cancel_reason: reason, cleanup_timer: cleanup_timer}
    job = maybe_start_cancel(state.adapter, job)
    {:ok, %{state | jobs: Map.put(state.jobs, reference, job)}}
  end

  defp request_cancel(state, _reference, _job, _reason), do: {:ok, state}

  defp maybe_start_cancel(_adapter, %{cancel_reason: nil} = job), do: job
  defp maybe_start_cancel(_adapter, %{port: nil} = job), do: job
  defp maybe_start_cancel(_adapter, %{cancel_worker: worker} = job) when is_pid(worker), do: job

  defp maybe_start_cancel(adapter, job) do
    case Exec.cancel(job.exec_state, job.cancel_reason) do
      {:ok, header} ->
        worker = spawn(fn -> adapter_module(adapter).cancel(job.port, header) end)
        %{job | cancel_worker: worker}

      {:error, _reason} ->
        job
    end
  end

  defp map_result(job, {:ok, terminal, stdout, stderr}) do
    duration = max(System.monotonic_time(:millisecond) - job.started_at, 0)

    execution = %ExecutionResult{
      build_key: job.build_key,
      outcome: terminal.outcome,
      exit_code: terminal.code,
      signal: terminal.signal,
      duration_ms: duration,
      stdout_tail: public_tail(stdout),
      stderr_tail: public_tail(stderr),
      discarded_bytes: %{stdout: terminal.discarded_stdout, stderr: terminal.discarded_stderr},
      cleanup: terminal.cleanup
    }

    cond do
      terminal.cleanup == :uncertain ->
        failure(:cleanup_unconfirmed, job.target, "Process cleanup was not confirmed")

      job.cancel_reason == :timeout ->
        failure(:build_timeout, job.target, "Process execution timed out")

      not is_nil(job.cancel_reason) ->
        failure(:cancelled, job.target, "Process execution was cancelled")

      true ->
        {:ok, %Result{execution: execution, stdout: stdout, stderr: stderr}}
    end
  end

  defp map_result(job, {:error, reason}) do
    cond do
      not is_nil(job.cancel_reason) ->
        failure(
          :cleanup_unconfirmed,
          job.target,
          "Cancelled process cleanup could not be confirmed"
        )

      reason == :helper_missing ->
        failure(:helper_missing, job.target, "Toolchain helper is unavailable")

      true ->
        failure(:io_failed, job.target, "Toolchain helper execution failed")
    end
  end

  defp worker_failure(job) do
    if job.cancel_reason,
      do:
        Failure.new!(
          target: job.target,
          stage: :execution,
          code: :cleanup_unconfirmed,
          message: "Process runner stopped before cleanup was confirmed"
        ),
      else:
        Failure.new!(
          target: job.target,
          stage: :execution,
          code: :io_failed,
          message: "Process runner stopped unexpectedly"
        )
  end

  defp record_shutdown_failure(
         %{admission: :stopping, shutdown_failures: failures},
         {:error, %Failure{code: :cleanup_unconfirmed} = failure}
       ),
       do: [failure | failures]

  defp record_shutdown_failure(state, _result), do: state.shutdown_failures

  defp maybe_finish_shutdown(%{admission: :stopping, jobs: jobs} = state)
       when map_size(jobs) == 0,
       do: finish_shutdown(state)

  defp maybe_finish_shutdown(state), do: state

  defp finish_shutdown(state) do
    result =
      case Enum.reverse(state.shutdown_failures) do
        [] -> :ok
        failures -> {:error, failures}
      end

    Enum.each(state.shutdown_waiters, fn waiter ->
      send(waiter.pid, {:rekindle_process_runner_shutdown, waiter.reference, result})
    end)

    %{
      state
      | admission: :stopped,
        shutdown_waiters: [],
        shutdown_failures: []
    }
  end

  defp public_tail(<<>>), do: <<>>

  defp public_tail(bytes) when is_binary(bytes) do
    source =
      if String.valid?(bytes), do: bytes, else: inspect(bytes, limit: 256, printable_limit: 8_000)

    case Redactor.sanitize(source) do
      {:ok, value} -> value
      _ -> "<redacted>"
    end
  end

  defp put_job(state, reference, job) do
    monitors =
      state.monitors
      |> Map.put(job.caller_monitor, {reference, :caller})
      |> Map.put(job.worker_monitor, {reference, :worker})

    %{state | jobs: Map.put(state.jobs, reference, job), monitors: monitors}
  end

  defp update_job(state, reference, fun) do
    case Map.fetch(state.jobs, reference) do
      {:ok, job} -> %{state | jobs: Map.put(state.jobs, reference, fun.(job))}
      :error -> state
    end
  end

  defp cleanup_job(job) do
    Process.cancel_timer(job.timer)
    if job.cleanup_timer, do: Process.cancel_timer(job.cleanup_timer)
    if job.cancel_worker, do: Process.exit(job.cancel_worker, :kill)
    Process.demonitor(job.caller_monitor, [:flush])
    Process.demonitor(job.worker_monitor, [:flush])
  end

  defp drop_monitors(monitors, job),
    do: monitors |> Map.delete(job.caller_monitor) |> Map.delete(job.worker_monitor)

  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp normalized_absolute?(value),
    do: is_binary(value) and Path.type(value) == :absolute and Path.expand(value) == value

  defp adapter_module({module, _options}), do: module
  defp adapter_module(module), do: module
  defp adapter_options({_module, options}) when is_list(options), do: options
  defp adapter_options(_module), do: []

  defp failure(code, target, message) do
    {:error,
     Failure.new!(
       target: if(target in [:web, :desktop], do: target, else: nil),
       stage: elem(Failure.stage_for(code), 1),
       code: code,
       message: message
     )}
  end
end
