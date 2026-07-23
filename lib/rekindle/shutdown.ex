defmodule Rekindle.Shutdown do
  @moduledoc false

  use GenServer

  alias Rekindle.ArtifactStore.Lease
  alias Rekindle.Shutdown.{Resource, Result}
  alias Rekindle.{ArtifactStore, EventBus, Failure, ProcessRunner}

  @max_shutdown_workers 32

  defstruct [
    :event_bus,
    :timeout_ms,
    :result,
    :resource_table,
    status: :accepting,
    process_runners: [],
    resource_indexes: %{cancel: [], notify: [], release: [], cleanup: []},
    resource_counts: %{cancel: 0, notify: 0, release: 0, cleanup: 0}
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

  @spec track_lease(GenServer.server(), Lease.t()) ::
          {:ok, reference()} | {:error, Failure.t()}
  def track_lease(server, %Lease{} = lease) do
    with {:ok, release} <- ArtifactStore.authorize_release(lease) do
      case track(server, :lease, release: fn -> ArtifactStore.release(release) end) do
        {:ok, _reference} = tracked ->
          tracked

        {:error, %Failure{}} = error ->
          _ = ArtifactStore.revoke_release_authority(release)
          error
      end
    end
  end

  @spec untrack(GenServer.server(), reference()) :: :ok
  def untrack(server, reference), do: GenServer.call(server, {:untrack, reference})

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
         admitted_runners?(runners) and
         (is_nil(event_bus) or valid_server?(event_bus)) and is_integer(timeout) and
         timeout in 100..120_000 do
      table = :ets.new(:rekindle_shutdown_resources, [:set, :private])

      {:ok,
       %__MODULE__{
         process_runners: runners,
         event_bus: event_bus,
         timeout_ms: timeout,
         resource_table: table
       }}
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
        cond do
          not resource_callbacks_supported?(resource) ->
            {:reply, {:error, contract("Shutdown resource is invalid")}, state}

          resource_capacity_available?(state, resource) ->
            reference = make_ref()
            entry = %{owner: owner, resource: resource}
            true = :ets.insert(state.resource_table, {reference, entry})
            {indexes, counts} = index_resource(state, reference, resource)

            {:reply, {:ok, reference},
             %{state | resource_indexes: indexes, resource_counts: counts}}

          true ->
            {:reply, {:error, contract("Shutdown resource capacity is exhausted")}, state}
        end

      :error ->
        {:reply, {:error, contract("Shutdown resource is invalid")}, state}
    end
  end

  def handle_call({:track, _kind, _callbacks}, _from, state),
    do: {:reply, {:error, cancelled("Shutdown has stopped new work")}, state}

  def handle_call({:untrack, _reference}, _from, %{resource_table: nil} = state),
    do: {:reply, :ok, state}

  def handle_call({:untrack, reference}, {owner, _tag}, state) do
    state =
      case :ets.lookup(state.resource_table, reference) do
        [{^reference, %{owner: ^owner, resource: resource}}] ->
          true = :ets.delete(state.resource_table, reference)
          remove_resource_index(state, reference, resource)

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:shutdown, _reason}, _from, %{status: :stopped} = state),
    do: {:reply, state.result, state}

  def handle_call({:shutdown, reason}, _from, %{status: :accepting} = state)
      when reason in [:shutdown, :supervisor, :configuration_changed] do
    result = perform(state, reason)
    state = retire_resources(state)
    {:reply, result, %{state | status: :stopped, result: result}}
  end

  def handle_call({:shutdown, _reason}, _from, state),
    do: {:reply, Result.new([contract("Shutdown reason is invalid")]), state}

  @impl true
  def terminate(_reason, %{status: :stopped}), do: :ok
  def terminate(_reason, state), do: perform(state, :supervisor) |> then(fn _ -> :ok end)

  defp perform(state, reason) do
    shutdown_deadline = deadline(state.timeout_ms)
    failures = emit_stopping(state.event_bus, reason, stage_deadline(shutdown_deadline, 7))

    failures =
      failures ++
        invoke(
          state,
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
          state,
          [:browser, :desktop],
          :notify,
          stage_deadline(shutdown_deadline, 4)
        )

    failures =
      failures ++ await_runners(runner_waits, stage_deadline(shutdown_deadline, 3))

    failures =
      failures ++
        invoke(state, [:lease], :release, stage_deadline(shutdown_deadline, 2))

    failures =
      failures ++
        invoke(
          state,
          [:staging, :publish, :generic, :browser, :desktop, :discovery, :build, :helper],
          :cleanup,
          shutdown_deadline
        )

    Result.new(failures)
  end

  defp emit_stopping(nil, _reason, _stage_deadline), do: []

  defp emit_stopping(event_bus, reason, event_deadline) do
    parent = self()
    reference = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:shutdown_event_emitted, reference, emit_stopping_sync(event_bus, reason)})
      end)

    work_deadline = work_deadline(event_deadline)
    remaining = max(work_deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:shutdown_event_emitted, ^reference, failures} when is_list(failures) ->
        Process.demonitor(monitor, [:flush])
        failures

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        [cleanup_failure("Shutdown event worker terminated without a result")]
    after
      remaining ->
        terminate_processes(%{reference => %{pid: pid, monitor: monitor}}, event_deadline)
        [cleanup_failure("Shutdown event emission timed out")]
    end
  end

  defp emit_stopping_sync(event_bus, reason) do
    attributes = %{
      target: nil,
      support_level: nil,
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
    work_deadline = work_deadline(runner_deadline)
    pending = spawn_runner_workers(runners, parent)
    await_runner_starts(pending, work_deadline, runner_deadline, %{}, [])
  end

  defp spawn_runner_workers(runners, parent) do
    Enum.reduce(runners, %{}, fn runner, pending ->
      token = make_ref()

      {pid, monitor} =
        spawn_monitor(fn ->
          begin_runner(parent, token, runner)
        end)

      Map.put(pending, token, %{pid: pid, monitor: monitor})
    end)
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

  defp await_runner_starts(pending, _work_deadline, _drain_deadline, waits, failures)
       when map_size(pending) == 0,
       do: {waits, Enum.reverse(failures)}

  defp await_runner_starts(pending, work_deadline, drain_deadline, waits, failures) do
    remaining = max(work_deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:shutdown_runner_started, token, outcome} ->
        case Map.pop(pending, token) do
          {nil, _pending} ->
            await_runner_starts(pending, work_deadline, drain_deadline, waits, failures)

          {entry, pending} ->
            case outcome do
              {:waiting, reference} ->
                wait = Map.put(entry, :reference, reference)

                await_runner_starts(
                  pending,
                  work_deadline,
                  drain_deadline,
                  Map.put(waits, token, wait),
                  failures
                )

              :stopped ->
                Process.demonitor(entry.monitor, [:flush])
                await_runner_starts(pending, work_deadline, drain_deadline, waits, failures)

              :error ->
                Process.demonitor(entry.monitor, [:flush])

                await_runner_starts(
                  pending,
                  work_deadline,
                  drain_deadline,
                  waits,
                  [runner_failure() | failures]
                )
            end
        end

      {:DOWN, monitor, :process, _pid, _reason} ->
        case pop_monitor(pending, monitor) do
          :error ->
            await_runner_starts(pending, work_deadline, drain_deadline, waits, failures)

          {:ok, _token, _entry, pending} ->
            await_runner_starts(
              pending,
              work_deadline,
              drain_deadline,
              waits,
              [runner_failure() | failures]
            )
        end
    after
      remaining ->
        terminate_processes(pending, drain_deadline)

        timeout_failures =
          Enum.map(pending, fn _entry ->
            cleanup_failure("Process runner shutdown initiation timed out")
          end)

        {waits, Enum.reverse(failures) ++ timeout_failures}
    end
  end

  defp await_runners(waits, _stage_deadline) when map_size(waits) == 0, do: []

  defp await_runners(waits, stage_deadline) do
    await_runner_results(waits, work_deadline(stage_deadline), stage_deadline)
  end

  defp await_runner_results(waits, _work_deadline, _drain_deadline)
       when map_size(waits) == 0,
       do: []

  defp await_runner_results(waits, work_deadline, drain_deadline) do
    remaining = max(work_deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:shutdown_runner_finished, token, :ok} ->
        case Map.pop(waits, token) do
          {nil, _waits} ->
            await_runner_results(waits, work_deadline, drain_deadline)

          {%{monitor: monitor}, waits} ->
            Process.demonitor(monitor, [:flush])
            await_runner_results(waits, work_deadline, drain_deadline)
        end

      {:shutdown_runner_finished, token, {:error, failures}} when is_list(failures) ->
        case Map.pop(waits, token) do
          {nil, _waits} ->
            await_runner_results(waits, work_deadline, drain_deadline)

          {%{monitor: monitor}, waits} ->
            Process.demonitor(monitor, [:flush])
            failures ++ await_runner_results(waits, work_deadline, drain_deadline)
        end

      {:DOWN, monitor, :process, _pid, _reason} ->
        case pop_monitor(waits, monitor) do
          :error ->
            await_runner_results(waits, work_deadline, drain_deadline)

          {:ok, _token, _entry, waits} ->
            [runner_failure() | await_runner_results(waits, work_deadline, drain_deadline)]
        end
    after
      remaining ->
        terminate_processes(waits, drain_deadline)
        [cleanup_failure("Process runner shutdown timed out")]
    end
  end

  defp invoke(state, kinds, callback, callback_deadline) do
    parent = self()
    work_deadline = work_deadline(callback_deadline)

    selected = indexed_resources(state, callback, kinds)
    pending = spawn_callback_workers(selected, parent, callback)
    await_callbacks(pending, callback, work_deadline, callback_deadline, [])
  end

  defp spawn_callback_workers(resources, parent, callback) do
    Enum.reduce(resources, %{}, fn resource, pending ->
      reference = make_ref()

      {pid, monitor} =
        spawn_monitor(fn ->
          result = invoke_callback(resource, callback)
          send(parent, {:shutdown_callback, reference, result})
        end)

      entry = %{pid: pid, monitor: monitor, kind: resource.kind}
      Map.put(pending, reference, entry)
    end)
  end

  defp indexed_resources(state, callback, kinds) do
    state.resource_indexes
    |> Map.fetch!(callback)
    |> Enum.flat_map(fn reference ->
      case :ets.lookup(state.resource_table, reference) do
        [{^reference, %{resource: resource}}] ->
          if resource.kind in kinds, do: [resource], else: []

        _ ->
          []
      end
    end)
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

  defp await_callbacks(pending, _callback, _work_deadline, _drain_deadline, failures)
       when map_size(pending) == 0,
       do: Enum.reverse(failures) |> List.flatten()

  defp await_callbacks(pending, callback, work_deadline, drain_deadline, failures) do
    remaining = max(work_deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:shutdown_callback, reference, callback_failures} when is_list(callback_failures) ->
        case Map.pop(pending, reference) do
          {nil, _pending} ->
            await_callbacks(pending, callback, work_deadline, drain_deadline, failures)

          {%{monitor: monitor}, pending} ->
            Process.demonitor(monitor, [:flush])

            await_callbacks(
              pending,
              callback,
              work_deadline,
              drain_deadline,
              [callback_failures | failures]
            )
        end

      {:DOWN, monitor, :process, _pid, _reason} ->
        case Enum.find(pending, fn {_reference, entry} -> entry.monitor == monitor end) do
          nil ->
            await_callbacks(pending, callback, work_deadline, drain_deadline, failures)

          {reference, entry} ->
            pending = Map.delete(pending, reference)
            failure = callback_failure(entry.kind, callback, "terminated without a result")

            await_callbacks(
              pending,
              callback,
              work_deadline,
              drain_deadline,
              [[failure] | failures]
            )
        end
    after
      remaining ->
        timeout_failures = terminate_callbacks(pending, callback, drain_deadline)
        Enum.reverse([timeout_failures | failures]) |> List.flatten()
    end
  end

  defp terminate_callbacks(pending, callback, drain_deadline) do
    terminate_processes(pending, drain_deadline)

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

  defp work_deadline(stage_deadline) do
    now = System.monotonic_time(:millisecond)
    remaining = max(stage_deadline - now, 0)
    min(now + max(div(remaining * 4, 5), 1), stage_deadline)
  end

  defp index_resource(state, reference, resource) do
    Enum.reduce(
      [:cancel, :notify, :release, :cleanup],
      {state.resource_indexes, state.resource_counts},
      fn callback, {indexes, counts} ->
        if eligible_callback?(resource, callback) do
          references = Map.fetch!(indexes, callback)
          counts = Map.update!(counts, callback, &(&1 + 1))
          {Map.put(indexes, callback, [reference | references]), counts}
        else
          {indexes, counts}
        end
      end
    )
  end

  defp resource_capacity_available?(state, resource) do
    Enum.all?([:cancel, :notify, :release, :cleanup], fn callback ->
      not eligible_callback?(resource, callback) or
        Map.fetch!(state.resource_counts, callback) < @max_shutdown_workers
    end)
  end

  defp resource_callbacks_supported?(resource) do
    Enum.all?([:cancel, :notify, :release, :cleanup], fn callback ->
      is_nil(Map.fetch!(resource, callback)) or eligible_callback?(resource, callback)
    end)
  end

  defp remove_resource_index(state, reference, resource) do
    Enum.reduce([:cancel, :notify, :release, :cleanup], state, fn callback, state ->
      if eligible_callback?(resource, callback) do
        references = Map.fetch!(state.resource_indexes, callback)
        references = List.delete(references, reference)
        count = max(Map.fetch!(state.resource_counts, callback) - 1, 0)

        %{
          state
          | resource_indexes: Map.put(state.resource_indexes, callback, references),
            resource_counts: Map.put(state.resource_counts, callback, count)
        }
      else
        state
      end
    end)
  end

  defp eligible_callback?(resource, :cancel),
    do:
      resource.kind in [:discovery, :build, :helper, :publish, :generic] and
        is_function(resource.cancel, 0)

  defp eligible_callback?(resource, :notify),
    do: resource.kind in [:browser, :desktop] and is_function(resource.notify, 0)

  defp eligible_callback?(resource, :release),
    do: resource.kind == :lease and is_function(resource.release, 0)

  defp eligible_callback?(resource, :cleanup),
    do:
      resource.kind in [
        :staging,
        :publish,
        :generic,
        :browser,
        :desktop,
        :discovery,
        :build,
        :helper
      ] and is_function(resource.cleanup, 0)

  defp eligible_callback?(_resource, _callback), do: false

  defp retire_resources(%{resource_table: nil} = state), do: state

  defp retire_resources(state) do
    table = state.resource_table

    janitor =
      spawn(fn ->
        receive do
          {:"ETS-TRANSFER", ^table, _owner, :shutdown} -> :ets.delete(table)
        end
      end)

    case :ets.give_away(table, janitor, :shutdown) do
      true ->
        %{
          state
          | resource_table: nil,
            resource_indexes: %{cancel: [], notify: [], release: [], cleanup: []},
            resource_counts: %{cancel: 0, notify: 0, release: 0, cleanup: 0}
        }

      false ->
        Process.exit(janitor, :kill)
        state
    end
  end

  defp admitted_runners?(runners) when is_list(runners), do: admitted_runners?(runners, 0)
  defp admitted_runners?(_runners), do: false

  defp admitted_runners?([], _count), do: true

  defp admitted_runners?([runner | runners], count) when count < @max_shutdown_workers,
    do: valid_server?(runner) and admitted_runners?(runners, count + 1)

  defp admitted_runners?([_runner | _runners], @max_shutdown_workers), do: false

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
