defmodule Rekindle.Scheduler.Session do
  @moduledoc false

  alias Rekindle.Failure
  alias Rekindle.Scheduler
  alias Rekindle.Scheduler.RevisionAllocator

  @enforce_keys [:allocator, :workers, :status, :callers]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          allocator: RevisionAllocator.t(),
          workers: map(),
          status: :active | :stopping,
          callers: %{optional(non_neg_integer()) => reference()}
        }

  @spec new(%{required(Rekindle.target()) => [atom()]}, map(), non_neg_integer()) ::
          {:ok, t(), non_neg_integer(), [term()]} | {:error, Failure.t()}
  def new(target_nodes, retained, debounce_ms)
      when is_map(target_nodes) and is_map(retained) and is_integer(debounce_ms) do
    targets = ordered_targets(Map.keys(target_nodes))

    with :ok <- valid_targets(targets, target_nodes, retained),
         revisions <- retained_revisions(targets, retained),
         {:ok, allocator, admission_revision} <- RevisionAllocator.new(revisions),
         {:ok, workers} <-
           workers(targets, target_nodes, retained, debounce_ms, admission_revision) do
      effects =
        Enum.flat_map(targets, fn target ->
          case workers[target].token_request do
            nil -> []
            request -> [{:request_token, target, request.id, request.revision}]
          end
        end)

      {:ok,
       %__MODULE__{
         allocator: allocator,
         workers: workers,
         status: :active,
         callers: %{}
       }, admission_revision, effects}
    end
  end

  def new(_target_nodes, _retained, _debounce_ms), do: invalid("Build session is invalid")

  @spec watch(t(), %{required(Rekindle.target()) => [atom()]}, non_neg_integer()) ::
          {:ok, t(), non_neg_integer(), [term()]} | {:error, Failure.t()}
  def watch(%__MODULE__{} = session, affected, now_ms)
      when is_map(affected) and is_integer(now_ms) and now_ms >= 0 do
    with :ok <- affected_workers(session, affected),
         :ok <- active(session),
         {:ok, allocator, revision} <- RevisionAllocator.allocate(session.allocator),
         {:ok, workers, effects} <-
           update_workers(session.workers, affected, fn worker, nodes ->
             Scheduler.change(worker, nodes, revision, now_ms)
           end) do
      session = %{session | allocator: allocator, workers: workers}
      {session, effects} = apply_effects(session, effects)
      {:ok, session, revision, effects}
    end
  end

  def watch(%__MODULE__{}, _affected, _now_ms), do: invalid("Watcher batch is invalid")

  @spec request(t(), Rekindle.target(), [atom()], reference()) ::
          {:ok, t(), non_neg_integer(), [term()]} | {:error, Failure.t()}
  def request(%__MODULE__{} = session, target, nodes, caller)
      when is_list(nodes) and is_reference(caller) do
    with {:ok, worker} <- fetch_worker(session, target),
         :ok <- active(session),
         :ok <- running(worker),
         false <- Enum.any?(session.callers, fn {_revision, current} -> current == caller end),
         {:ok, allocator, revision} <- RevisionAllocator.allocate(session.allocator),
         {:ok, worker, effects} <- Scheduler.request(worker, nodes, revision) do
      session = %{
        session
        | allocator: allocator,
          workers: Map.put(session.workers, target, worker),
          callers: Map.put(session.callers, revision, caller)
      }

      {session, effects} = apply_effects(session, qualify_effects(target, effects))
      {:ok, session, revision, effects}
    else
      true -> invalid("Build caller is already pending")
      {:error, _} = error -> error
    end
  end

  def request(%__MODULE__{}, _target, _nodes, _caller), do: invalid("Build request is invalid")

  @spec detach_caller(t(), reference()) :: {:ok, t()} | {:error, Failure.t()}
  def detach_caller(%__MODULE__{} = session, caller) when is_reference(caller) do
    case Enum.find(session.callers, fn {_revision, current} -> current == caller end) do
      {revision, ^caller} -> {:ok, %{session | callers: Map.delete(session.callers, revision)}}
      nil -> invalid("Build caller is not pending")
    end
  end

  def detach_caller(%__MODULE__{}, _caller), do: invalid("Build caller is invalid")

  @spec ready(t(), Rekindle.target(), non_neg_integer()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def ready(%__MODULE__{} = session, target, now_ms) do
    update_worker(session, target, fn worker -> Scheduler.ready(worker, now_ms) end)
  end

  @spec grant(t(), Rekindle.target(), String.t(), non_neg_integer()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def grant(%__MODULE__{} = session, target, id, revision) do
    update_worker(session, target, fn worker -> Scheduler.grant(worker, id, revision) end)
  end

  @spec advance(t(), Rekindle.target(), non_neg_integer(), :validating | :publishing) ::
          {:ok, t()} | {:obsolete, t()} | {:error, Failure.t()}
  def advance(%__MODULE__{} = session, target, revision, stage) do
    with {:ok, worker} <- fetch_worker(session, target) do
      case Scheduler.advance(worker, revision, stage) do
        {:ok, worker} -> {:ok, replace_worker(session, worker)}
        {:obsolete, worker} -> {:obsolete, replace_worker(session, worker)}
        {:error, _} = error -> error
      end
    end
  end

  @spec succeed(t(), Rekindle.target(), non_neg_integer(), term(), term()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def succeed(%__MODULE__{} = session, target, revision, generation, caller_result) do
    with {:ok, session, effects} <-
           update_worker(session, target, fn worker ->
             Scheduler.succeed(worker, revision, generation)
           end) do
      {:ok, session, attach_success(caller_result, effects)}
    end
  end

  @spec fail(t(), Rekindle.target(), non_neg_integer(), Failure.t()) ::
          {:ok, t(), [term()]} | {:error, Failure.t()}
  def fail(%__MODULE__{} = session, target, revision, %Failure{} = failure) do
    update_worker(session, target, fn worker -> Scheduler.fail(worker, revision, failure) end)
  end

  def fail(%__MODULE__{}, _target, _revision, _failure),
    do: invalid("Build failure is invalid")

  @spec stop(t()) :: {:ok, t(), [term()]}
  def stop(%__MODULE__{status: :stopping} = session), do: {:ok, session, []}

  def stop(%__MODULE__{} = session) do
    {workers, effects} =
      session.workers
      |> Enum.sort_by(fn {target, _worker} -> target_rank(target) end)
      |> Enum.reduce({%{}, []}, fn {target, worker}, {workers, effects} ->
        {:ok, worker, worker_effects} = Scheduler.stop(worker)

        {Map.put(workers, target, worker), effects ++ qualify_effects(target, worker_effects)}
      end)

    session = %{session | workers: workers, status: :stopping}
    {session, effects} = apply_effects(session, effects)
    {:ok, session, effects}
  end

  @spec health(t()) :: :ready | :degraded
  def health(%__MODULE__{} = session) do
    if Enum.any?(session.workers, fn {_target, worker} -> worker.last_failure != nil end),
      do: :degraded,
      else: :ready
  end

  defp workers(targets, target_nodes, retained, debounce_ms, admission_revision) do
    Enum.reduce_while(targets, {:ok, %{}}, fn target, {:ok, workers} ->
      case Scheduler.new(target, debounce_ms, admission_revision, Map.get(retained, target)) do
        {:ok, worker} ->
          worker =
            if is_nil(worker.active_generation),
              do: %{worker | affected_nodes: Map.fetch!(target_nodes, target)},
              else: worker

          {:cont, {:ok, Map.put(workers, target, worker)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp update_workers(workers, affected, callback) do
    affected
    |> Enum.sort_by(fn {target, _nodes} -> target_rank(target) end)
    |> Enum.reduce_while({:ok, workers, []}, fn {target, nodes}, {:ok, workers, effects} ->
      case callback.(Map.fetch!(workers, target), nodes) do
        {:ok, worker, worker_effects} ->
          {:cont,
           {:ok, Map.put(workers, target, worker),
            effects ++ qualify_effects(target, worker_effects)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp qualify_effects(target, effects), do: Enum.map(effects, &Tuple.insert_at(&1, 1, target))

  defp retained_revisions(targets, retained) do
    Enum.flat_map(targets, fn target ->
      case Map.get(retained, target) do
        nil -> []
        %{source_revision: revision} -> [revision]
      end
    end)
  end

  defp affected_workers(session, affected) do
    cond do
      map_size(affected) == 0 ->
        invalid("Watcher targets are invalid")

      Enum.any?(affected, fn {target, _nodes} ->
        match?(%Scheduler{state: :stopping}, Map.get(session.workers, target))
      end) ->
        stopped()

      Enum.all?(affected, fn {target, nodes} ->
        Map.has_key?(session.workers, target) and is_list(nodes) and nodes != []
      end) ->
        :ok

      true ->
        invalid("Watcher targets are invalid")
    end
  end

  defp fetch_worker(session, target) do
    case Map.fetch(session.workers, target) do
      {:ok, worker} -> {:ok, worker}
      :error -> invalid("Build target is not selected")
    end
  end

  defp update_worker(session, target, callback) do
    with {:ok, worker} <- fetch_worker(session, target),
         {:ok, worker, effects} <- callback.(worker) do
      session = replace_worker(session, worker)
      {session, effects} = apply_effects(session, qualify_effects(target, effects))
      {:ok, session, effects}
    end
  end

  defp replace_worker(session, %Scheduler{target: target} = worker),
    do: %{session | workers: Map.put(session.workers, target, worker)}

  defp apply_effects(session, effects) do
    Enum.reduce(effects, {session, []}, fn effect, {session, emitted} ->
      case terminal_effect(effect) do
        {:terminal, _target, revision, result} ->
          {caller, callers} = Map.pop(session.callers, revision)
          session = %{session | callers: callers}
          caller_effect = if caller, do: [{:caller, caller, result}], else: []
          {session, emitted ++ [effect] ++ caller_effect}

        :nonterminal ->
          {session, emitted ++ [effect]}
      end
    end)
  end

  defp terminal_effect({:cancelled, target, revision, reason}) do
    {:terminal, target, revision, {:error, cancelled(target, reason)}}
  end

  defp terminal_effect({:failed, target, revision, %Failure{} = failure}),
    do: {:terminal, target, revision, {:error, failure}}

  defp terminal_effect({:activated, target, revision, generation}),
    do: {:terminal, target, revision, {:ok, generation}}

  defp terminal_effect({:obsolete, target, revision}),
    do: {:terminal, target, revision, {:error, cancelled(target, :obsolete)}}

  defp terminal_effect(_effect), do: :nonterminal

  defp attach_success(caller_result, effects) do
    Enum.map(effects, fn
      {:caller, caller, {:ok, _generation}} -> {:caller, caller, {:ok, caller_result}}
      effect -> effect
    end)
  end

  defp cancelled(target, reason) do
    Failure.new!(
      target: target,
      stage: :execution,
      code: :cancelled,
      message: if(reason == :shutdown, do: "Build session stopped", else: "Build was superseded")
    )
  end

  defp running(%Scheduler{state: :stopping}), do: stopped()

  defp running(%Scheduler{}), do: :ok

  defp active(%__MODULE__{status: :active}), do: :ok
  defp active(%__MODULE__{status: :stopping}), do: stopped()

  defp stopped do
    {:error,
     Failure.new!(
       target: nil,
       stage: :execution,
       code: :cancelled,
       message: "Build session is stopping"
     )}
  end

  defp valid_targets(targets, target_nodes, retained) do
    if targets != [] and targets == Enum.uniq(targets) and
         Enum.all?(targets, &(&1 in [:web, :desktop])) and
         Enum.all?(Map.keys(retained), &(&1 in targets)) and
         Enum.all?(retained, fn {_target, value} -> valid_retained?(value) end) and
         Enum.all?(target_nodes, fn {target, nodes} ->
           Scheduler.validate_nodes(target, nodes) == :ok
         end),
       do: :ok,
       else: invalid("Build session targets are invalid")
  end

  defp ordered_targets(targets), do: Enum.sort_by(targets, &target_rank/1)
  defp target_rank(:web), do: 0
  defp target_rank(:desktop), do: 1
  defp target_rank(_target), do: 2

  defp valid_retained?(%{source_revision: revision, generation: generation} = retained),
    do:
      Enum.sort(Map.keys(retained)) == [:generation, :source_revision] and
        is_integer(revision) and revision in 0..9_007_199_254_740_991 and
        not is_nil(generation)

  defp valid_retained?(_value), do: false

  defp invalid(message) do
    {:error,
     Failure.new!(target: nil, stage: :internal, code: :contract_violation, message: message)}
  end
end
