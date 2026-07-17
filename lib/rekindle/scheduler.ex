defmodule Rekindle.Scheduler do
  @moduledoc false

  alias Rekindle.Failure

  @states ~w[idle debouncing building validating publishing active stopping]a

  @enforce_keys [:target, :debounce_ms]
  defstruct @enforce_keys ++
              [
                state: :idle,
                latest_source_revision: 0,
                running_revision: nil,
                queued_revision: nil,
                affected_nodes: [],
                queued_nodes: [],
                debounce_deadline_ms: nil,
                active_generation: nil,
                cancel_requested?: false
              ]

  @type t :: %__MODULE__{}

  @spec new(Rekindle.target(), non_neg_integer()) :: {:ok, t()} | {:error, Failure.t()}
  def new(target, debounce_ms)
      when target in [:web, :desktop] and is_integer(debounce_ms) and debounce_ms in 0..2_000,
      do: {:ok, %__MODULE__{target: target, debounce_ms: debounce_ms}}

  def new(_target, _debounce_ms), do: invalid("Scheduler configuration is invalid")

  @spec change(t(), [atom()], non_neg_integer()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def change(%__MODULE__{state: :stopping} = scheduler, _nodes, _now_ms),
    do: {:ok, scheduler, [:rejected]}

  def change(%__MODULE__{} = scheduler, nodes, now_ms)
      when is_list(nodes) and is_integer(now_ms) and now_ms >= 0 do
    with {:ok, nodes} <- normalize_nodes(scheduler.target, nodes) do
      revision = scheduler.latest_source_revision + 1
      deadline = now_ms + scheduler.debounce_ms

      case scheduler.state do
        state when state in [:idle, :active, :debouncing] ->
          {:ok,
           %{
             scheduler
             | state: :debouncing,
               latest_source_revision: revision,
               affected_nodes: merge_nodes(scheduler.affected_nodes, nodes),
               debounce_deadline_ms: deadline
           }, []}

        state when state in [:building, :validating, :publishing] ->
          cancel? = state in [:building, :validating] and not scheduler.cancel_requested?
          effects = if cancel?, do: [{:cancel, scheduler.running_revision}], else: []

          {:ok,
           %{
             scheduler
             | latest_source_revision: revision,
               queued_revision: revision,
               queued_nodes: merge_nodes(scheduler.queued_nodes, nodes),
               debounce_deadline_ms: deadline,
               cancel_requested?: scheduler.cancel_requested? or cancel?
           }, effects}
      end
    end
  end

  def change(%__MODULE__{}, _nodes, _now_ms), do: invalid("Scheduler change is invalid")

  @spec ready(t(), non_neg_integer()) ::
          {:ok, t(), :none | {:start, pos_integer(), [atom()]}} | {:error, Failure.t()}
  def ready(%__MODULE__{state: :debouncing} = scheduler, now_ms)
      when is_integer(now_ms) and now_ms >= 0 do
    if now_ms >= scheduler.debounce_deadline_ms do
      revision = scheduler.queued_revision || scheduler.latest_source_revision
      nodes = merge_nodes(scheduler.affected_nodes, scheduler.queued_nodes)

      {:ok,
       %{
         scheduler
         | state: :building,
           running_revision: revision,
           queued_revision: nil,
           affected_nodes: nodes,
           queued_nodes: [],
           debounce_deadline_ms: nil,
           cancel_requested?: false
       }, {:start, revision, nodes}}
    else
      {:ok, scheduler, :none}
    end
  end

  def ready(%__MODULE__{} = scheduler, _now_ms), do: {:ok, scheduler, :none}

  @spec advance(t(), pos_integer(), :validating | :publishing) ::
          {:ok, t()} | {:obsolete, t()} | {:error, Failure.t()}
  def advance(
        %__MODULE__{state: :building, running_revision: revision} = scheduler,
        revision,
        :validating
      ),
      do: {:ok, %{scheduler | state: :validating}}

  def advance(
        %__MODULE__{state: :validating, running_revision: revision} = scheduler,
        revision,
        :publishing
      ) do
    if revision == scheduler.latest_source_revision,
      do: {:ok, %{scheduler | state: :publishing}},
      else: {:obsolete, scheduler}
  end

  def advance(%__MODULE__{} = scheduler, revision, _stage)
      when is_integer(revision) and revision != scheduler.running_revision,
      do: {:obsolete, scheduler}

  def advance(%__MODULE__{}, _revision, _stage), do: invalid("Scheduler transition is invalid")

  @spec succeed(t(), pos_integer(), term(), non_neg_integer()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def succeed(
        %__MODULE__{state: :stopping, running_revision: revision} = scheduler,
        revision,
        _generation,
        _now_ms
      ),
      do: {:ok, scheduler, []}

  def succeed(
        %__MODULE__{state: :publishing, running_revision: revision} = scheduler,
        revision,
        generation,
        now_ms
      ) do
    if revision == scheduler.latest_source_revision do
      scheduler = %{scheduler | active_generation: generation}
      terminal(scheduler, now_ms, [{:activated, revision, generation}])
    else
      terminal(scheduler, now_ms, [{:obsolete, revision}])
    end
  end

  def succeed(%__MODULE__{running_revision: revision} = scheduler, revision, _generation, now_ms)
      when scheduler.state in [:building, :validating] and
             revision != scheduler.latest_source_revision,
      do: terminal(scheduler, now_ms, [{:cached_obsolete, revision}])

  def succeed(%__MODULE__{}, _revision, _generation, _now_ms),
    do: invalid("Scheduler success is invalid")

  @spec fail(t(), pos_integer(), Failure.t(), non_neg_integer()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def fail(
        %__MODULE__{state: :stopping, running_revision: revision} = scheduler,
        revision,
        %Failure{},
        _now_ms
      ),
      do: {:ok, scheduler, []}

  def fail(
        %__MODULE__{running_revision: revision} = scheduler,
        revision,
        %Failure{} = failure,
        now_ms
      )
      when scheduler.state in [:building, :validating, :publishing],
      do: terminal(scheduler, now_ms, [{:failed, revision, failure}])

  def fail(%__MODULE__{}, _revision, _failure, _now_ms),
    do: invalid("Scheduler failure is invalid")

  @spec stop(t()) :: {:ok, t(), [term()]}
  def stop(%__MODULE__{} = scheduler) do
    effects =
      if scheduler.state in [:building, :validating] and not scheduler.cancel_requested?,
        do: [{:cancel, scheduler.running_revision}],
        else: []

    {:ok,
     %{
       scheduler
       | state: :stopping,
         queued_revision: nil,
         queued_nodes: [],
         debounce_deadline_ms: nil,
         cancel_requested?: scheduler.cancel_requested? or effects != []
     }, effects}
  end

  @spec states() :: [atom()]
  def states, do: @states

  defp terminal(scheduler, now_ms, effects) do
    if scheduler.queued_revision do
      {:ok,
       %{
         scheduler
         | state: :debouncing,
           running_revision: nil,
           affected_nodes: scheduler.queued_nodes,
           queued_nodes: [],
           queued_revision: nil,
           debounce_deadline_ms: max(now_ms, scheduler.debounce_deadline_ms || now_ms),
           cancel_requested?: false
       }, effects}
    else
      state = if scheduler.active_generation, do: :active, else: :idle

      {:ok,
       %{
         scheduler
         | state: state,
           running_revision: nil,
           affected_nodes: [],
           debounce_deadline_ms: nil,
           cancel_requested?: false
       }, effects}
    end
  end

  defp normalize_nodes(target, nodes) do
    allowed =
      if target == :web,
        do: ~w[cargo_web external_web bindgen_web package_web seal_web]a,
        else: ~w[cargo_desktop external_desktop seal_desktop]a

    if Enum.all?(nodes, &(&1 in allowed)),
      do: {:ok, Enum.sort(Enum.uniq(nodes))},
      else: invalid("Scheduler nodes do not belong to the target")
  end

  defp merge_nodes(left, right), do: Enum.sort(Enum.uniq(left ++ right))

  defp invalid(message) do
    {:error,
     Failure.new!(target: nil, stage: :internal, code: :unexpected_state, message: message)}
  end
end
