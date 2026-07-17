defmodule Rekindle.Scheduler.ResourcePool do
  @moduledoc false

  alias Rekindle.Failure

  @enforce_keys [:max_cargo, :max_helpers]
  defstruct @enforce_keys ++ [cargo: %{}, helpers: MapSet.new(), targets: %{}]

  @type t :: %__MODULE__{}

  @spec new(pos_integer(), pos_integer()) :: {:ok, t()} | {:error, Failure.t()}
  def new(max_cargo, max_helpers)
      when is_integer(max_cargo) and max_cargo in 1..16 and is_integer(max_helpers) and
             max_helpers in 1..16,
      do: {:ok, %__MODULE__{max_cargo: max_cargo, max_helpers: max_helpers}}

  def new(_max_cargo, _max_helpers), do: invalid("Scheduler resource limits are invalid")

  @spec acquire_cargo(t(), term(), String.t()) ::
          {:ok, t()} | {:busy, :capacity | :cache_key, t()} | {:error, Failure.t()}
  def acquire_cargo(%__MODULE__{} = pool, owner, cache_key)
      when not is_nil(owner) and is_binary(cache_key) and cache_key != "" do
    cond do
      Map.has_key?(pool.cargo, owner) ->
        invalid("Cargo owner already holds a lease")

      map_size(pool.cargo) >= pool.max_cargo ->
        {:busy, :capacity, pool}

      cache_key in Map.values(pool.cargo) ->
        {:busy, :cache_key, pool}

      true ->
        {:ok, %{pool | cargo: Map.put(pool.cargo, owner, cache_key)}}
    end
  end

  def acquire_cargo(%__MODULE__{}, _owner, _cache_key),
    do: invalid("Cargo lease request is invalid")

  @spec release_cargo(t(), term()) :: {:ok, t()} | {:error, Failure.t()}
  def release_cargo(%__MODULE__{} = pool, owner) do
    if Map.has_key?(pool.cargo, owner),
      do: {:ok, %{pool | cargo: Map.delete(pool.cargo, owner)}},
      else: invalid("Cargo owner does not hold a lease")
  end

  @spec acquire_helper(t(), term()) ::
          {:ok, t()} | {:busy, :capacity, t()} | {:error, Failure.t()}
  def acquire_helper(%__MODULE__{} = pool, owner) when not is_nil(owner) do
    cond do
      MapSet.member?(pool.helpers, owner) -> invalid("Helper owner already holds a lease")
      MapSet.size(pool.helpers) >= pool.max_helpers -> {:busy, :capacity, pool}
      true -> {:ok, %{pool | helpers: MapSet.put(pool.helpers, owner)}}
    end
  end

  def acquire_helper(%__MODULE__{}, _owner), do: invalid("Helper lease request is invalid")

  @spec release_helper(t(), term()) :: {:ok, t()} | {:error, Failure.t()}
  def release_helper(%__MODULE__{} = pool, owner) do
    if MapSet.member?(pool.helpers, owner),
      do: {:ok, %{pool | helpers: MapSet.delete(pool.helpers, owner)}},
      else: invalid("Helper owner does not hold a lease")
  end

  @spec acquire_target(t(), Rekindle.target(), term()) ::
          {:ok, t()} | {:busy, :target, t()} | {:error, Failure.t()}
  def acquire_target(%__MODULE__{} = pool, target, owner)
      when target in [:web, :desktop] and not is_nil(owner) do
    case Map.fetch(pool.targets, target) do
      :error -> {:ok, %{pool | targets: Map.put(pool.targets, target, owner)}}
      {:ok, ^owner} -> invalid("Target owner already holds the publication lock")
      {:ok, _other} -> {:busy, :target, pool}
    end
  end

  def acquire_target(%__MODULE__{}, _target, _owner),
    do: invalid("Target publication lock request is invalid")

  @spec release_target(t(), Rekindle.target(), term()) :: {:ok, t()} | {:error, Failure.t()}
  def release_target(%__MODULE__{} = pool, target, owner) do
    if Map.get(pool.targets, target) == owner,
      do: {:ok, %{pool | targets: Map.delete(pool.targets, target)}},
      else: invalid("Target publication lock is not owned by the caller")
  end

  defp invalid(message) do
    {:error,
     Failure.new!(target: nil, stage: :internal, code: :unexpected_state, message: message)}
  end
end
