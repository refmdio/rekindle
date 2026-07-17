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
    failures = emit_stopping(state.event_bus, reason)

    failures =
      failures ++ invoke(resources, [:discovery, :build, :helper, :publish, :generic], :cancel)

    {runner_waits, runner_failures} = begin_runner_shutdown(state.process_runners)
    failures = failures ++ runner_failures
    failures = failures ++ invoke(resources, [:browser, :desktop], :notify)
    failures = failures ++ await_runners(runner_waits, deadline(state.timeout_ms))
    failures = failures ++ invoke(resources, [:lease], :release)

    failures =
      failures ++
        invoke(
          resources,
          [:staging, :publish, :generic, :browser, :desktop, :discovery, :build, :helper],
          :cleanup
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

  defp begin_runner_shutdown(runners) do
    Enum.reduce(runners, {[], []}, fn runner, {waits, failures} ->
      case ProcessRunner.begin_shutdown(runner) do
        {:ok, :stopped} -> {waits, failures}
        {:ok, reference} -> {[reference | waits], failures}
        _ -> {waits, [cleanup_failure("Process runner shutdown could not start") | failures]}
      end
    end)
  rescue
    _ -> {[], [cleanup_failure("Process runner shutdown could not start")]}
  catch
    _, _ -> {[], [cleanup_failure("Process runner shutdown could not start")]}
  end

  defp await_runners([], _deadline), do: []

  defp await_runners(references, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:rekindle_process_runner_shutdown, reference, :ok} ->
        await_runners(List.delete(references, reference), deadline)

      {:rekindle_process_runner_shutdown, reference, {:error, failures}}
      when is_list(failures) ->
        failures ++ await_runners(List.delete(references, reference), deadline)
    after
      remaining -> [cleanup_failure("Process runner shutdown timed out")]
    end
  end

  defp invoke(resources, kinds, callback) do
    resources
    |> Enum.filter(&(&1.kind in kinds))
    |> Enum.flat_map(&invoke_callback(&1, callback))
  end

  defp invoke_callback(resource, callback) do
    case Map.fetch!(resource, callback) do
      nil -> []
      function -> normalize_callback(function.(), resource.kind, callback)
    end
  rescue
    _ -> [cleanup_failure("Shutdown #{callback} callback failed")]
  catch
    _, _ -> [cleanup_failure("Shutdown #{callback} callback failed")]
  end

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
