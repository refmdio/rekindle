defmodule Rekindle.EventBus do
  @moduledoc false
  use GenServer

  alias Rekindle.{Event, Failure}

  @subscriber_watermark 1_024
  @ordered_types [
    :build_started,
    :stage_started,
    :stage_progress,
    :stage_finished,
    :build_succeeded,
    :build_failed,
    :build_cancelled
  ]

  defstruct [
    :otp_app,
    :project_session,
    :watermark,
    sequence: 0,
    status: :running,
    subscribers: %{},
    monitors: %{},
    ordering: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    otp_app = Keyword.fetch!(options, :otp_app)
    name = {:via, Registry, {Rekindle.RuntimeRegistry, {:events, otp_app}}}
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec subscribe(GenServer.server(), pid()) :: {:ok, reference()} | {:error, :not_running}
  def subscribe(server, subscriber \\ self()),
    do: GenServer.call(server, {:subscribe, subscriber})

  @spec unsubscribe(GenServer.server(), pid(), reference()) :: :ok | {:error, :not_owner}
  def unsubscribe(server, subscriber \\ self(), reference),
    do: GenServer.call(server, {:unsubscribe, subscriber, reference})

  @spec emit(GenServer.server(), keyword() | map()) :: {:ok, Event.t()} | {:error, Failure.t()}
  def emit(server, attributes), do: GenServer.call(server, {:emit, attributes})

  @impl true
  def init(options) do
    session =
      Keyword.get_lazy(options, :project_session, fn ->
        :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      end)

    if is_atom(Keyword.get(options, :otp_app)) and Regex.match?(~r/\A[0-9a-f]{32}\z/, session) and
         Keyword.keys(options) -- [:otp_app, :project_session] == [] do
      {:ok,
       %__MODULE__{
         otp_app: options[:otp_app],
         project_session: session,
         watermark: @subscriber_watermark
       }}
    else
      {:stop, :invalid_event_bus}
    end
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) when is_pid(subscriber) do
    if state.status == :running do
      reference = make_ref()
      monitor = Process.monitor(subscriber)
      entry = %{pid: subscriber, monitor: monitor}

      {:reply, {:ok, reference},
       %{
         state
         | subscribers: Map.put(state.subscribers, reference, entry),
           monitors: Map.put(state.monitors, monitor, reference)
       }}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  def handle_call({:unsubscribe, subscriber, reference}, _from, state) do
    case Map.get(state.subscribers, reference) do
      %{pid: ^subscriber} -> {:reply, :ok, drop_subscriber(state, reference)}
      %{pid: _owner} -> {:reply, {:error, :not_owner}, state}
      nil -> {:reply, :ok, state}
    end
  end

  def handle_call({:emit, _attributes}, _from, %{status: :stopped} = state),
    do: {:reply, unexpected(), state}

  def handle_call({:emit, attributes}, _from, state) do
    attributes =
      attributes
      |> Map.new()
      |> Map.merge(%{project_session: state.project_session, sequence: state.sequence})

    with {:ok, event} <- Event.new(attributes),
         :ok <- validate_order(state, event) do
      state = record_event(state, event)
      emit_telemetry(event)
      state = publish(state, event)
      state = if event.type == :session_stopping, do: %{state | status: :stopped}, else: state
      {:reply, {:ok, event}, state}
    else
      {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
      :error -> {:reply, unexpected(), state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, monitor) do
      nil -> {:noreply, state}
      reference -> {:noreply, drop_subscriber(state, reference)}
    end
  end

  defp validate_order(state, %Event{target: target, source_revision: revision} = event)
       when not is_nil(target) and not is_nil(revision) and event.type in @ordered_types do
    case Map.get(state.ordering, target) do
      nil ->
        if event.type == :build_started, do: :ok, else: :error

      %{revision: current} when revision < current ->
        :error

      %{revision: current} when revision > current ->
        if event.type == :build_started, do: :ok, else: :error

      %{terminal?: true} ->
        :error

      current ->
        validate_current(current, event)
    end
  end

  defp validate_order(_state, _event), do: :ok

  defp record_event(state, event) do
    ordering = record_order(state.ordering, event)
    %{state | sequence: state.sequence + 1, ordering: ordering}
  end

  defp record_order(ordering, %Event{type: type} = event) when type in @ordered_types do
    current =
      case Map.get(ordering, event.target) do
        %{revision: revision} = current when revision == event.source_revision ->
          current

        _other ->
          %{
            revision: event.source_revision,
            terminal?: false,
            stages: event.payload.stages,
            stage_index: 0,
            active_stage: nil,
            progress: nil,
            stages_succeeded?: true
          }
      end

    current =
      cond do
        Event.terminal?(event) ->
          %{current | terminal?: true, active_stage: nil, progress: nil}

        event.type == :stage_started ->
          %{current | active_stage: event.payload.stage, progress: nil}

        event.type == :stage_progress ->
          %{
            current
            | progress: %{
                completed: event.payload.completed,
                total: event.payload.total,
                unit: event.payload.unit
              }
          }

        event.type == :stage_finished ->
          %{
            current
            | stage_index: current.stage_index + 1,
              active_stage: nil,
              progress: nil,
              stages_succeeded?: current.stages_succeeded? and event.payload.result == :ok
          }

        true ->
          current
      end

    Map.put(ordering, event.target, current)
  end

  defp record_order(ordering, _event), do: ordering

  defp validate_current(_current, %Event{type: :build_started}), do: :error

  defp validate_current(%{active_stage: nil} = current, %Event{type: :stage_started} = event) do
    if Enum.at(current.stages, current.stage_index) == event.payload.stage, do: :ok, else: :error
  end

  defp validate_current(%{active_stage: stage, progress: progress}, %Event{
         type: :stage_progress,
         payload: %{stage: stage} = payload
       }) do
    cond do
      is_nil(progress) -> :ok
      payload.completed < progress.completed -> :error
      payload.total != progress.total -> :error
      payload.unit != progress.unit -> :error
      true -> :ok
    end
  end

  defp validate_current(%{active_stage: stage}, %Event{
         type: :stage_finished,
         payload: %{stage: stage}
       }),
       do: :ok

  defp validate_current(current, %Event{type: :build_succeeded}) do
    if current.stages_succeeded? and is_nil(current.active_stage) and
         current.stage_index == length(current.stages),
       do: :ok,
       else: :error
  end

  defp validate_current(_current, %Event{type: type})
       when type in [:build_failed, :build_cancelled],
       do: :ok

  defp validate_current(_current, _event), do: :error

  defp publish(state, event) do
    Enum.reduce(Map.keys(state.subscribers), state, fn reference, acc ->
      case Map.get(acc.subscribers, reference) do
        nil ->
          acc

        %{pid: pid} ->
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, count} when count < acc.watermark ->
              send(pid, {:rekindle, reference, {:event, event}})

              if event.type == :session_stopping,
                do: close_subscriber(acc, reference, :session_stopped),
                else: acc

            _ ->
              close_subscriber(acc, reference, :overflow)
          end
      end
    end)
  end

  defp close_subscriber(state, reference, reason) do
    case Map.get(state.subscribers, reference) do
      %{pid: pid} ->
        state = drop_subscriber(state, reference)
        send(pid, {:rekindle, reference, {:closed, reason}})
        state

      nil ->
        state
    end
  end

  defp drop_subscriber(state, reference) do
    case Map.pop(state.subscribers, reference) do
      {nil, _} ->
        state

      {%{monitor: monitor}, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{state | subscribers: subscribers, monitors: Map.delete(state.monitors, monitor)}
    end
  end

  defp emit_telemetry(event) do
    case telemetry(event) do
      nil ->
        :ok

      {name, measurements, event_metadata} ->
        metadata =
          %{
            project_session_digest: session_digest(event.project_session),
            target: event.target,
            stage: nil,
            profile: nil,
            source_revision: event.source_revision,
            result_code: nil,
            compatibility_tuple_id: nil
          }
          |> Map.merge(event_metadata)

        :telemetry.execute(name, measurements, metadata)
    end
  end

  defp telemetry(%Event{type: :build_started, payload: payload}),
    do:
      {[:rekindle, :build, :start], %{monotonic_time: System.monotonic_time()},
       %{profile: payload.profile}}

  defp telemetry(%Event{type: type, payload: payload})
       when type in [:build_failed, :build_cancelled] do
    code = if type == :build_failed, do: payload.failure_code, else: payload.reason
    count = if type == :build_failed, do: payload.diagnostic_count, else: 0

    {[:rekindle, :build, :stop],
     %{monotonic_time: System.monotonic_time(), diagnostics_count: count}, %{result_code: code}}
  end

  defp telemetry(%Event{type: :build_succeeded}),
    do:
      {[:rekindle, :build, :stop],
       %{monotonic_time: System.monotonic_time(), diagnostics_count: 0}, %{result_code: :ok}}

  defp telemetry(%Event{type: :stage_started, payload: payload}),
    do:
      {[:rekindle, :stage, :start],
       %{monotonic_time: System.monotonic_time(), input_bytes: payload.input_bytes || 0},
       %{stage: payload.stage}}

  defp telemetry(%Event{type: :stage_finished, payload: payload}),
    do:
      {[:rekindle, :stage, :stop],
       %{
         duration_ms: payload.duration_ms,
         input_bytes: payload.input_bytes,
         output_bytes: payload.output_bytes
       }, %{stage: payload.stage, result_code: payload.result}}

  defp telemetry(%Event{type: :generation_published}),
    do: {[:rekindle, :generation, :published], %{}, %{result_code: :ok}}

  defp telemetry(%Event{type: :browser_state, payload: %{state: state}} = event) do
    suffix =
      case state do
        :joined -> :connected
        :applied -> :applied
        :failed -> :failed
        _ -> nil
      end

    if suffix,
      do: {[:rekindle, :browser, suffix], %{}, %{result_code: event.payload.failure_code || :ok}},
      else: nil
  end

  defp telemetry(%Event{type: :desktop_state, payload: %{state: state}} = event) do
    suffix =
      case state do
        :spawning -> :started
        :ready -> :ready
        value when value in [:stopping, :exited] -> :stopped
        :failed -> :failed
        _ -> nil
      end

    if suffix,
      do: {[:rekindle, :desktop, suffix], %{}, %{result_code: result_code(event)}},
      else: nil
  end

  defp telemetry(%Event{type: :projection_finished, payload: payload}),
    do:
      {[:rekindle, :projection, :stop], %{},
       %{result_code: if(payload.result == :succeeded, do: :ok, else: :failed)}}

  defp telemetry(_event), do: nil

  defp result_code(%Event{payload: %{state: :failed}}), do: :failed
  defp result_code(_event), do: :ok

  defp session_digest(session),
    do: :crypto.hash(:sha256, session) |> Base.encode16(case: :lower)

  defp unexpected do
    {:error,
     Failure.new!(
       target: nil,
       stage: :internal,
       code: :unexpected_state,
       message: "Event ordering is invalid"
     )}
  end
end
