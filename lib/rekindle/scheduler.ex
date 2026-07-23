defmodule Rekindle.Scheduler do
  @moduledoc false

  alias Rekindle.Failure

  @safe_integer 9_007_199_254_740_991
  @states ~w[idle debouncing building validating publishing active failed stopping]a

  @enforce_keys [:target, :debounce_ms, :latest_source_revision]
  defstruct @enforce_keys ++
              [
                state: :idle,
                pending_revision: nil,
                token_request: nil,
                running_revision: nil,
                queued_revision: nil,
                affected_nodes: [],
                queued_nodes: [],
                debounce_deadline_ms: nil,
                active_generation: nil,
                last_failure: nil,
                cancel_requested?: false,
                running_terminal?: false
              ]

  @type t :: %__MODULE__{}

  @spec new(Rekindle.target(), non_neg_integer(), non_neg_integer(), map() | nil) ::
          {:ok, t()} | {:error, Failure.t()}
  def new(target, debounce_ms, admission_revision, retained_generation \\ nil)

  def new(target, debounce_ms, admission_revision, retained_generation)
      when target in [:web, :desktop] and is_integer(debounce_ms) and debounce_ms in 0..2_000 and
             is_integer(admission_revision) and admission_revision in 0..@safe_integer do
    with {:ok, state, generation} <- retained(retained_generation, admission_revision) do
      scheduler = %__MODULE__{
        target: target,
        debounce_ms: debounce_ms,
        latest_source_revision: admission_revision,
        state: state,
        active_generation: generation
      }

      if is_nil(generation) do
        {:ok, request_token(%{scheduler | pending_revision: admission_revision}, []) |> elem(0)}
      else
        {:ok, scheduler}
      end
    end
  end

  def new(_target, _debounce_ms, _admission_revision, _retained_generation),
    do: invalid("Scheduler configuration is invalid")

  @spec change(t(), [atom()], non_neg_integer(), non_neg_integer()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def change(%__MODULE__{state: :stopping} = scheduler, _nodes, _revision, _now_ms),
    do: {:ok, scheduler, [:rejected]}

  def change(%__MODULE__{} = scheduler, nodes, revision, now_ms)
      when is_list(nodes) and is_integer(revision) and is_integer(now_ms) and now_ms >= 0 do
    with :ok <- newer_revision(scheduler, revision),
         {:ok, nodes} <- normalize_nodes(scheduler.target, nodes) do
      case scheduler.state do
        state when state in [:idle, :active, :failed, :debouncing] ->
          replace_pending(scheduler, nodes, revision, now_ms + scheduler.debounce_ms, false)

        state when state in [:building, :validating, :publishing] ->
          queue(scheduler, nodes, revision)
      end
    end
  end

  def change(%__MODULE__{}, _nodes, _revision, _now_ms),
    do: invalid("Scheduler change is invalid")

  @spec request(t(), [atom()], non_neg_integer()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def request(%__MODULE__{state: :stopping}, _nodes, _revision),
    do: stopped()

  def request(%__MODULE__{} = scheduler, nodes, revision) when is_list(nodes) do
    with :ok <- newer_revision(scheduler, revision),
         {:ok, nodes} <- normalize_nodes(scheduler.target, nodes) do
      case scheduler.state do
        state when state in [:idle, :active, :failed, :debouncing] ->
          replace_pending(scheduler, nodes, revision, nil, true)

        state when state in [:building, :validating, :publishing] ->
          queue(scheduler, nodes, revision)
      end
    end
  end

  def request(%__MODULE__{}, _nodes, _revision),
    do: invalid("Scheduler request is invalid")

  @spec ready(t(), non_neg_integer()) :: {:ok, t(), [term()]} | {:error, Failure.t()}
  def ready(
        %__MODULE__{
          state: :debouncing,
          pending_revision: _revision,
          token_request: nil,
          debounce_deadline_ms: deadline
        } = scheduler,
        now_ms
      )
      when is_integer(now_ms) and now_ms >= 0 and is_integer(deadline) do
    if now_ms >= deadline do
      {scheduler, effects} = request_token(%{scheduler | debounce_deadline_ms: nil}, [])
      {:ok, scheduler, effects}
    else
      {:ok, scheduler, []}
    end
  end

  def ready(%__MODULE__{} = scheduler, now_ms) when is_integer(now_ms) and now_ms >= 0,
    do: {:ok, scheduler, []}

  def ready(%__MODULE__{}, _now_ms), do: invalid("Scheduler deadline is invalid")

  @spec grant(t(), String.t(), non_neg_integer()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def grant(
        %__MODULE__{
          token_request: %{id: id, revision: revision},
          pending_revision: revision
        } = scheduler,
        id,
        revision
      )
      when is_binary(id) and byte_size(id) == 32 do
    {:ok,
     %{
       scheduler
       | state: :building,
         pending_revision: nil,
         token_request: nil,
         running_revision: revision,
         debounce_deadline_ms: nil,
         cancel_requested?: false,
         running_terminal?: false
     }, [{:start, revision, scheduler.affected_nodes}]}
  end

  def grant(%__MODULE__{} = scheduler, id, revision)
      when is_binary(id) and is_integer(revision) and revision in 0..@safe_integer,
      do: {:ok, scheduler, [{:release_token, id, revision}]}

  def grant(%__MODULE__{}, _id, _revision), do: invalid("Scheduler token grant is invalid")

  @spec advance(t(), non_neg_integer(), :validating | :publishing) ::
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

  def advance(%__MODULE__{running_revision: running} = scheduler, revision, _stage)
      when is_integer(revision) and revision in 0..@safe_integer and revision != running,
      do: {:obsolete, scheduler}

  def advance(%__MODULE__{}, _revision, _stage),
    do: invalid("Scheduler transition is invalid")

  @spec succeed(t(), non_neg_integer(), term()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def succeed(%__MODULE__{state: :stopping} = scheduler, _revision, _generation),
    do: {:ok, scheduler, []}

  def succeed(
        %__MODULE__{
          state: :publishing,
          running_revision: revision,
          running_terminal?: terminal?
        } = scheduler,
        revision,
        generation
      ) do
    if revision == scheduler.latest_source_revision do
      scheduler = %{scheduler | active_generation: generation, last_failure: nil}
      terminal(scheduler, [{:activated, revision, generation}])
    else
      effect = if terminal?, do: {:published_obsolete, revision}, else: {:obsolete, revision}
      terminal(scheduler, [effect])
    end
  end

  def succeed(%__MODULE__{running_revision: revision} = scheduler, revision, _generation)
      when scheduler.state in [:building, :validating] and
             revision != scheduler.latest_source_revision,
      do: terminal(scheduler, [{:cached_obsolete, revision}])

  def succeed(%__MODULE__{running_revision: running} = scheduler, revision, _generation)
      when is_integer(revision) and revision in 0..@safe_integer and revision != running,
      do: {:ok, scheduler, []}

  def succeed(%__MODULE__{}, _revision, _generation),
    do: invalid("Scheduler success is invalid")

  @spec fail(t(), non_neg_integer(), Failure.t()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def fail(%__MODULE__{state: :stopping} = scheduler, _revision, %Failure{}),
    do: {:ok, scheduler, []}

  def fail(
        %__MODULE__{running_revision: revision, running_terminal?: true} = scheduler,
        revision,
        %Failure{}
      )
      when scheduler.state in [:building, :validating, :publishing],
      do: terminal(scheduler, [{:discarded, revision}])

  def fail(
        %__MODULE__{running_revision: revision, running_terminal?: false} = scheduler,
        revision,
        %Failure{} = failure
      )
      when scheduler.state in [:building, :validating, :publishing] do
    scheduler =
      if failure.code == :cancelled and revision < scheduler.latest_source_revision do
        scheduler
      else
        %{
          scheduler
          | last_failure: %{
              source_revision: revision,
              stage: failure.stage,
              code: failure.code
            }
        }
      end

    terminal(scheduler, [{:failed, revision, failure}])
  end

  def fail(%__MODULE__{running_revision: running} = scheduler, revision, %Failure{})
      when is_integer(revision) and revision in 0..@safe_integer and revision != running,
      do: {:ok, scheduler, []}

  def fail(%__MODULE__{}, _revision, _failure),
    do: invalid("Scheduler failure is invalid")

  @spec stop(t()) :: {:ok, t(), [term()]}
  def stop(%__MODULE__{state: :stopping} = scheduler), do: {:ok, scheduler, []}

  def stop(%__MODULE__{} = scheduler) do
    revisions =
      [
        scheduler.pending_revision,
        if(scheduler.running_terminal?, do: nil, else: scheduler.running_revision),
        scheduler.queued_revision
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    effects =
      cancel_token_effect(scheduler.token_request) ++
        if(
          not is_nil(scheduler.running_revision) and
            scheduler.state in [:building, :validating] and
            not scheduler.cancel_requested?,
          do: [{:cancel, scheduler.running_revision, :shutdown}],
          else: []
        ) ++ Enum.map(revisions, &{:cancelled, &1, :shutdown})

    {:ok,
     %{
       scheduler
       | state: :stopping,
         pending_revision: nil,
         token_request: nil,
         running_revision: nil,
         queued_revision: nil,
         affected_nodes: [],
         queued_nodes: [],
         debounce_deadline_ms: nil,
         cancel_requested?: false,
         running_terminal?: false
     }, effects}
  end

  @spec public_state(t()) :: map()
  def public_state(%__MODULE__{} = scheduler) do
    %{
      phase: scheduler.state,
      source_revision: scheduler.latest_source_revision,
      active_generation: scheduler.active_generation,
      last_failure: scheduler.last_failure
    }
  end

  @spec states() :: [atom()]
  def states, do: @states

  @spec validate_nodes(Rekindle.target(), [atom()]) :: :ok | {:error, Failure.t()}
  def validate_nodes(target, nodes) do
    case normalize_nodes(target, nodes) do
      {:ok, _nodes} -> :ok
      {:error, _} = error -> error
    end
  end

  defp replace_pending(scheduler, nodes, revision, deadline, immediate?) do
    effects =
      cancel_token_effect(scheduler.token_request) ++
        superseded_effect(scheduler.pending_revision, revision)

    scheduler = %{
      scheduler
      | state: :debouncing,
        latest_source_revision: revision,
        pending_revision: revision,
        token_request: nil,
        affected_nodes: merge_nodes(scheduler.affected_nodes, nodes),
        debounce_deadline_ms: deadline,
        cancel_requested?: false
    }

    if immediate? do
      {scheduler, token_effects} = request_token(scheduler, effects)
      {:ok, scheduler, token_effects}
    else
      {:ok, scheduler, effects}
    end
  end

  defp queue(scheduler, nodes, revision) do
    cancel_running? =
      scheduler.state in [:building, :validating] and not scheduler.cancel_requested?

    supersede_running? = is_nil(scheduler.queued_revision)

    effects =
      superseded_effect(scheduler.queued_revision, revision) ++
        if(cancel_running?, do: [{:cancel, scheduler.running_revision, :obsolete}], else: []) ++
        if(supersede_running?,
          do: [{:cancelled, scheduler.running_revision, :obsolete}],
          else: []
        )

    {:ok,
     %{
       scheduler
       | latest_source_revision: revision,
         queued_revision: revision,
         queued_nodes: merge_nodes(scheduler.queued_nodes, nodes),
         cancel_requested?: scheduler.cancel_requested? or cancel_running?,
         running_terminal?: scheduler.running_terminal? or supersede_running?
     }, effects}
  end

  defp terminal(scheduler, effects) do
    resting_state =
      cond do
        scheduler.last_failure -> :failed
        scheduler.active_generation -> :active
        true -> :idle
      end

    if scheduler.queued_revision do
      scheduler = %{
        scheduler
        | state: resting_state,
          pending_revision: scheduler.queued_revision,
          running_revision: nil,
          queued_revision: nil,
          affected_nodes: scheduler.queued_nodes,
          queued_nodes: [],
          debounce_deadline_ms: nil,
          cancel_requested?: false,
          running_terminal?: false
      }

      {scheduler, effects} = request_token(scheduler, effects)
      {:ok, scheduler, effects}
    else
      {:ok,
       %{
         scheduler
         | state: resting_state,
           pending_revision: nil,
           token_request: nil,
           running_revision: nil,
           affected_nodes: [],
           debounce_deadline_ms: nil,
           cancel_requested?: false,
           running_terminal?: false
       }, effects}
    end
  end

  defp request_token(%{pending_revision: revision} = scheduler, effects) do
    request = %{
      id: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
      revision: revision
    }

    {%{scheduler | token_request: request}, effects ++ [{:request_token, request.id, revision}]}
  end

  defp cancel_token_effect(nil), do: []
  defp cancel_token_effect(%{id: id, revision: revision}), do: [{:cancel_token, id, revision}]

  defp superseded_effect(nil, _revision), do: []

  defp superseded_effect(previous, revision) when previous != revision,
    do: [{:cancelled, previous, :obsolete}]

  defp superseded_effect(_previous, _revision), do: []

  defp retained(nil, _admission_revision), do: {:ok, :idle, nil}

  defp retained(
         %{source_revision: revision, generation: generation} = retained,
         admission_revision
       )
       when is_integer(revision) and revision in 0..@safe_integer and
              revision <= admission_revision and not is_nil(generation) do
    if Enum.sort(Map.keys(retained)) == [:generation, :source_revision],
      do: {:ok, :active, generation},
      else: invalid("Retained generation is invalid")
  end

  defp retained(_retained, _admission_revision),
    do: invalid("Retained generation is invalid")

  defp newer_revision(scheduler, revision) do
    if is_integer(revision) and revision in 0..@safe_integer and
         revision > scheduler.latest_source_revision,
       do: :ok,
       else: invalid("Scheduler revision is invalid")
  end

  defp normalize_nodes(target, nodes) do
    allowed =
      if target == :web,
        do: ~w[cargo_web external_web bindgen_web package_web seal_web]a,
        else: ~w[cargo_desktop external_desktop seal_desktop]a

    if nodes != [] and Enum.all?(nodes, &(&1 in allowed)),
      do: {:ok, Enum.sort(Enum.uniq(nodes))},
      else: invalid("Scheduler nodes do not belong to the target")
  end

  defp merge_nodes(left, right), do: Enum.sort(Enum.uniq(left ++ right))

  defp stopped do
    {:error,
     Failure.new!(
       target: nil,
       stage: :execution,
       code: :cancelled,
       message: "Build session is stopping"
     )}
  end

  defp invalid(message) do
    {:error,
     Failure.new!(target: nil, stage: :internal, code: :contract_violation, message: message)}
  end
end
