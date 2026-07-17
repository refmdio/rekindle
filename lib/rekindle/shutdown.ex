defmodule Rekindle.Shutdown do
  @moduledoc false

  use GenServer

  alias Rekindle.Shutdown.{Resource, Result}
  alias Rekindle.{EventBus, Failure, ProcessRunner}

  defstruct [
    :event_bus,
    :timeout_ms,
    :result,
    status: :accepting,
    process_runners: [],
    resources: %{},
    waiters: []
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name)
    options = Keyword.delete(options, :name)
    GenServer.start_link(__MODULE__, options, if(name, do: [name: name], else: []))
  end

  @spec admit(GenServer.server()) :: :ok | {:error, Failure.t()}
  def admit(server), do: GenServer.call(server, :admit)

  @spec track(GenServer.server(), Resource.kind(), keyword()) ::
          {:ok, reference()} | {:error, Failure.t()}
  def track(server, kind, callbacks), do: GenServer.call(server, {:track, kind, callbacks})

  @spec untrack(GenServer.server(), reference()) :: :ok
  def untrack(server, reference), do: GenServer.call(server, {:untrack, self(), reference})

  @spec shutdown(GenServer.server(), :shutdown | :supervisor | :configuration_changed) ::
          Result.t()
  def shutdown(server, reason \\ :shutdown),
    do: GenServer.call(server, {:shutdown, reason}, :infinity)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    runners = Keyword.get(options, :process_runners, [])
    event_bus = Keyword.get(options, :event_bus)
    timeout = Keyword.get(options, :timeout_ms, 35_000)

    if Keyword.keys(options) -- [:process_runners, :event_bus, :timeout_ms] == [] and
         is_list(runners) and Enum.all?(runners, &valid_server?/1) and
         (is_nil(event_bus) or valid_server?(event_bus)) and is_integer(timeout) and
         timeout in 100..120_000 do
      {:ok, %__MODULE__{process_runners: runners, event_bus: event_bus, timeout_ms: timeout}}
    else
      {:stop, :invalid_shutdown_coordinator}
    end
  end

  @impl true
  def handle_call(:admit, _from, %{status: :accepting} = state), do: {:reply, :ok, state}

  def handle_call(:admit, _from, state),
    do: {:reply, {:error, cancelled("Shutdown has stopped new work")}, state}

  def handle_call({:track, kind, callbacks}, {owner, _tag}, %{status: :accepting} = state) do
    case Resource.new(kind, callbacks) do
      {:ok, resource} ->
        reference = make_ref()
        entry = %{owner: owner, resource: resource}

        {:reply, {:ok, reference},
         %{state | resources: Map.put(state.resources, reference, entry)}}

      :error ->
        {:reply, {:error, contract("Shutdown resource is invalid")}, state}
    end
  end

  def handle_call({:track, _kind, _callbacks}, _from, state),
    do: {:reply, {:error, cancelled("Shutdown has stopped new work")}, state}

  def handle_call({:untrack, owner, reference}, _from, state) do
    resources =
      case Map.get(state.resources, reference) do
        %{owner: ^owner} -> Map.delete(state.resources, reference)
        _ -> state.resources
      end

    {:reply, :ok, %{state | resources: resources}}
  end

  def handle_call({:shutdown, _reason}, _from, %{status: :stopped} = state),
    do: {:reply, state.result, state}

  def handle_call({:shutdown, _reason}, from, %{status: :stopping} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call({:shutdown, reason}, from, %{status: :accepting} = state)
      when reason in [:shutdown, :supervisor, :configuration_changed] do
    parent = self()
    snapshot = state
    spawn(fn -> send(parent, {:shutdown_finished, perform(snapshot, reason)}) end)
    {:noreply, %{state | status: :stopping, waiters: [from]}}
  end

  def handle_call({:shutdown, _reason}, _from, state),
    do: {:reply, Result.new([contract("Shutdown reason is invalid")]), state}

  @impl true
  def handle_info({:shutdown_finished, %Result{} = result}, state) do
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    {:noreply, %{state | status: :stopped, result: result, resources: %{}, waiters: []}}
  end

  @impl true
  def terminate(_reason, %{status: :stopped}), do: :ok
  def terminate(_reason, state), do: perform(state, :supervisor) |> then(fn _ -> :ok end)

  defp perform(state, reason) do
    resources = Enum.map(state.resources, fn {_reference, entry} -> entry.resource end)
    shutdown_deadline = deadline(state.timeout_ms)
    failures = emit_stopping(state.event_bus, reason)

    failures =
      failures ++
        invoke(
          resources,
          [:discovery, :build, :helper, :publish, :generic],
          :cancel,
          stage_deadline(shutdown_deadline, 6)
        )

    {runner_waits, runner_failures} =
      begin_runner_shutdown(
        state.process_runners,
        stage_deadline(shutdown_deadline, 5)
      )

    failures = failures ++ runner_failures

    failures =
      failures ++
        invoke(
          resources,
          [:browser, :desktop],
          :notify,
          stage_deadline(shutdown_deadline, 4)
        )

    failures =
      failures ++ await_runners(runner_waits, stage_deadline(shutdown_deadline, 3))

    failures =
      failures ++
        invoke(resources, [:lease], :release, stage_deadline(shutdown_deadline, 2))

    failures =
      failures ++
        invoke(
          resources,
          [:staging, :publish, :generic, :browser, :desktop, :discovery, :build, :helper],
          :cleanup,
          shutdown_deadline
        )

    Result.new(failures)
  end

  defp emit_stopping(nil, _reason), do: []

  defp emit_stopping(event_bus, reason) do
    attributes = %{
      target: nil,
      source_revision: nil,
      generation_id: nil,
      type: :session_stopping,
      payload: %{reason: reason}
    }

    case EventBus.emit(event_bus, attributes) do
      {:ok, _event} -> []
      {:error, %Failure{} = failure} -> [failure]
      _ -> [cleanup_failure("Shutdown event could not be emitted")]
    end
  rescue
    _ -> [cleanup_failure("Shutdown event could not be emitted")]
  catch
    _, _ -> [cleanup_failure("Shutdown event could not be emitted")]
  end

  defp begin_runner_shutdown(runners, runner_deadline) do
    parent = self()

    pending =
      Map.new(runners, fn runner ->
        token = make_ref()

        {pid, monitor} =
          spawn_monitor(fn ->
            begin_runner(parent, token, runner)
          end)

        {token, %{pid: pid, monitor: monitor}}
      end)

    await_runner_starts(pending, runner_deadline, %{}, [])
  end

  defp begin_runner(parent, token, runner) do
    case ProcessRunner.begin_shutdown(runner) do
      {:ok, :stopped} ->
        send(parent, {:shutdown_runner_started, token, :stopped})

      {:ok, reference} ->
        send(parent, {:shutdown_runner_started, token, {:waiting, reference}})

        receive do
          {:rekindle_process_runner_shutdown, ^reference, result} ->
            send(parent, {:shutdown_runner_finished, token, result})
        end

      _ ->
        send(parent, {:shutdown_runner_started, token, :error})
    end
  rescue
    _ -> send(parent, {:shutdown_runner_started, token, :error})
  catch
    _, _ -> send(parent, {:shutdown_runner_started, token, :error})
  end

  defp await_runner_starts(pending, _deadline, waits, failures) when map_size(pending) == 0,
    do: {waits, Enum.reverse(failures)}

  defp await_runner_starts(pending, runner_deadline, waits, failures) do
    remaining = max(runner_deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:shutdown_runner_started, token, outcome} ->
        case Map.pop(pending, token) do
          {nil, _pending} ->
            await_runner_starts(pending, runner_deadline, waits, failures)

          {entry, pending} ->
            case outcome do
              {:waiting, reference} ->
                wait = Map.put(entry, :reference, reference)

                await_runner_starts(
                  pending,
                  runner_deadline,
                  Map.put(waits, token, wait),
                  failures
                )

              :stopped ->
                Process.demonitor(entry.monitor, [:flush])
                await_runner_starts(pending, runner_deadline, waits, failures)

              :error ->
                Process.demonitor(entry.monitor, [:flush])

                await_runner_starts(pending, runner_deadline, waits, [runner_failure() | failures])
            end
        end

      {:DOWN, monitor, :process, _pid, _reason} ->
        case pop_monitor(pending, monitor) do
          :error ->
            await_runner_starts(pending, runner_deadline, waits, failures)

          {:ok, _token, _entry, pending} ->
            await_runner_starts(pending, runner_deadline, waits, [runner_failure() | failures])
        end
    after
      remaining ->
        terminate_processes(pending, runner_deadline)

        timeout_failures =
          Enum.map(pending, fn _entry ->
            cleanup_failure("Process runner shutdown initiation timed out")
          end)

        {waits, Enum.reverse(failures) ++ timeout_failures}
    end
  end

  defp await_runners(waits, _deadline) when map_size(waits) == 0, do: []

  defp await_runners(waits, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:shutdown_runner_finished, token, :ok} ->
        case Map.pop(waits, token) do
          {nil, _waits} ->
            await_runners(waits, deadline)

          {%{monitor: monitor}, waits} ->
            Process.demonitor(monitor, [:flush])
            await_runners(waits, deadline)
        end

      {:shutdown_runner_finished, token, {:error, failures}} when is_list(failures) ->
        case Map.pop(waits, token) do
          {nil, _waits} ->
            await_runners(waits, deadline)

          {%{monitor: monitor}, waits} ->
            Process.demonitor(monitor, [:flush])
            failures ++ await_runners(waits, deadline)
        end

      {:DOWN, monitor, :process, _pid, _reason} ->
        case pop_monitor(waits, monitor) do
          :error -> await_runners(waits, deadline)
          {:ok, _token, _entry, waits} -> [runner_failure() | await_runners(waits, deadline)]
        end
    after
      remaining ->
        terminate_processes(waits, deadline)
        [cleanup_failure("Process runner shutdown timed out")]
    end
  end

  defp invoke(resources, kinds, callback, callback_deadline) do
    parent = self()

    pending =
      resources
      |> Enum.filter(&(&1.kind in kinds and not is_nil(Map.fetch!(&1, callback))))
      |> Map.new(fn resource ->
        reference = make_ref()

        {pid, monitor} =
          spawn_monitor(fn ->
            result = invoke_callback(resource, callback)
            send(parent, {:shutdown_callback, reference, result})
          end)

        {reference, %{pid: pid, monitor: monitor, kind: resource.kind}}
      end)

    await_callbacks(pending, callback, callback_deadline, [])
  end

  defp invoke_callback(resource, callback) do
    resource
    |> Map.fetch!(callback)
    |> then(&normalize_callback(&1.(), resource.kind, callback))
  rescue
    _ -> [cleanup_failure("Shutdown #{callback} callback failed")]
  catch
    _, _ -> [cleanup_failure("Shutdown #{callback} callback failed")]
  end

  defp await_callbacks(pending, _callback, _deadline, failures) when map_size(pending) == 0,
    do: Enum.reverse(failures) |> List.flatten()

  defp await_callbacks(pending, callback, callback_deadline, failures) do
    remaining = max(callback_deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:shutdown_callback, reference, callback_failures} when is_list(callback_failures) ->
        case Map.pop(pending, reference) do
          {nil, _pending} ->
            await_callbacks(pending, callback, callback_deadline, failures)

          {%{monitor: monitor}, pending} ->
            Process.demonitor(monitor, [:flush])
            await_callbacks(pending, callback, callback_deadline, [callback_failures | failures])
        end

      {:DOWN, monitor, :process, _pid, _reason} ->
        case Enum.find(pending, fn {_reference, entry} -> entry.monitor == monitor end) do
          nil ->
            await_callbacks(pending, callback, callback_deadline, failures)

          {reference, entry} ->
            pending = Map.delete(pending, reference)
            failure = callback_failure(entry.kind, callback, "terminated without a result")
            await_callbacks(pending, callback, callback_deadline, [[failure] | failures])
        end
    after
      remaining ->
        timeout_failures = terminate_callbacks(pending, callback)
        Enum.reverse([timeout_failures | failures]) |> List.flatten()
    end
  end

  defp terminate_callbacks(pending, callback) do
    terminate_processes(pending, System.monotonic_time(:millisecond))

    Enum.map(pending, fn {reference, entry} ->
      receive do
        {:shutdown_callback, ^reference, _result} -> :ok
      after
        0 -> :ok
      end

      callback_failure(entry.kind, callback, "timed out")
    end)
  end

  defp terminate_processes(entries, drain_deadline) do
    Enum.each(entries, fn {_token, entry} -> Process.exit(entry.pid, :kill) end)
    drain_processes(entries, drain_deadline)
  end

  defp drain_processes(entries, _deadline) when map_size(entries) == 0, do: :ok

  defp drain_processes(entries, drain_deadline) do
    remaining = max(drain_deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, monitor, :process, _pid, _reason} ->
        case pop_monitor(entries, monitor) do
          :error -> drain_processes(entries, drain_deadline)
          {:ok, _token, _entry, entries} -> drain_processes(entries, drain_deadline)
        end
    after
      remaining ->
        Enum.each(entries, fn {_token, entry} ->
          Process.demonitor(entry.monitor, [:flush])
        end)

        :ok
    end
  end

  defp pop_monitor(entries, monitor) do
    case Enum.find(entries, fn {_token, entry} -> entry.monitor == monitor end) do
      nil -> :error
      {token, entry} -> {:ok, token, entry, Map.delete(entries, token)}
    end
  end

  defp runner_failure,
    do: cleanup_failure("Process runner shutdown could not start or complete")

  defp callback_failure(kind, callback, reason),
    do: cleanup_failure("Shutdown #{callback} callback for #{kind} #{reason}")

  defp normalize_callback(:ok, _kind, _callback), do: []

  defp normalize_callback({:error, %Failure{} = failure}, _kind, _callback) do
    case Failure.sanitize(failure) do
      {:ok, failure} -> [failure]
      _ -> [cleanup_failure("Shutdown callback returned an invalid failure")]
    end
  end

  defp normalize_callback(_result, _kind, callback),
    do: [cleanup_failure("Shutdown #{callback} callback returned an invalid result")]

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp stage_deadline(shutdown_deadline, remaining_stages) do
    now = System.monotonic_time(:millisecond)
    remaining = max(shutdown_deadline - now, 0)
    min(now + max(div(remaining, remaining_stages), 1), shutdown_deadline)
  end

  defp valid_server?(value), do: is_pid(value) or is_atom(value) or is_tuple(value)

  defp cancelled(message),
    do: Failure.new!(target: nil, stage: :execution, code: :cancelled, message: message)

  defp cleanup_failure(message),
    do:
      Failure.new!(
        target: nil,
        stage: :execution,
        code: :cleanup_unconfirmed,
        message: message
      )

  defp contract(message),
    do: Failure.new!(target: nil, stage: :internal, code: :contract_violation, message: message)
end
