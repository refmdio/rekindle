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

  @spec subscribe(GenServer.server(), pid()) :: {:ok, reference()}
  def subscribe(server, subscriber \\ self()),
    do: GenServer.call(server, {:subscribe, subscriber})

  @spec unsubscribe(GenServer.server(), pid(), reference()) :: :ok
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
    reference = make_ref()
    monitor = Process.monitor(subscriber)
    entry = %{pid: subscriber, monitor: monitor}

    {:reply, {:ok, reference},
     %{
       state
       | subscribers: Map.put(state.subscribers, reference, entry),
         monitors: Map.put(state.monitors, monitor, reference)
     }}
  end

  def handle_call({:unsubscribe, subscriber, reference}, _from, state) do
    case Map.get(state.subscribers, reference) do
      %{pid: ^subscriber} -> {:reply, :ok, drop_subscriber(state, reference)}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:emit, attributes}, _from, state) do
    attributes =
      attributes
      |> Map.new()
      |> Map.merge(%{project_session: state.project_session, sequence: state.sequence})

    with {:ok, event} <- Event.new(attributes),
         :ok <- validate_order(state, event) do
      state = record_event(state, event)
      emit_telemetry(event)
      {:reply, {:ok, event}, publish(state, event)}
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
        :ok

      %{revision: current} when revision < current ->
        :error

      %{revision: current} when revision > current ->
        :ok

      %{terminal?: true} ->
        :error

      %{progress: progress} when event.type == :stage_progress ->
        prior = Map.get(progress, event.payload.stage, -1)
        if event.payload.completed >= prior, do: :ok, else: :error

      _current ->
        :ok
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
        %{revision: revision} = current when revision == event.source_revision -> current
        _other -> %{revision: event.source_revision, terminal?: false, progress: %{}}
      end

    current =
      cond do
        Event.terminal?(event) ->
          %{current | terminal?: true, progress: %{}}

        event.type == :stage_progress ->
          %{
            current
            | progress: Map.put(current.progress, event.payload.stage, event.payload.completed)
          }

        true ->
          current
      end

    Map.put(ordering, event.target, current)
  end

  defp record_order(ordering, _event), do: ordering

  defp publish(state, event) do
    Enum.reduce(Map.keys(state.subscribers), state, fn reference, acc ->
      case Map.get(acc.subscribers, reference) do
        nil ->
          acc

        %{pid: pid} ->
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, count} when count < acc.watermark ->
              send(pid, {:rekindle_event, reference, event})
              acc

            _ ->
              drop_subscriber(acc, reference)
          end
      end
    end)
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
    :telemetry.execute(
      [:rekindle, :event, event.type],
      %{sequence: event.sequence},
      %{
        project_session: event.project_session,
        target: event.target,
        source_revision: event.source_revision,
        generation_id: event.generation_id,
        type: event.type
      }
    )
  end

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
