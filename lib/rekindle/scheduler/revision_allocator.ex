defmodule Rekindle.Scheduler.RevisionAllocator do
  @moduledoc false

  alias Rekindle.Failure

  @safe_integer 9_007_199_254_740_991
  @enforce_keys [:current]
  defstruct @enforce_keys

  @type t :: %__MODULE__{current: non_neg_integer()}

  @spec new([non_neg_integer()]) :: {:ok, t(), non_neg_integer()} | {:error, Failure.t()}
  def new(retained_revisions) when is_list(retained_revisions) do
    if Enum.all?(retained_revisions, &safe_revision?/1) do
      seed = if retained_revisions == [], do: -1, else: Enum.max(retained_revisions)

      case increment(seed) do
        {:ok, revision} -> {:ok, %__MODULE__{current: revision}, revision}
        :overflow -> overflow()
      end
    else
      invalid()
    end
  end

  def new(_retained_revisions), do: invalid()

  @spec allocate(t()) :: {:ok, t(), non_neg_integer()} | {:error, Failure.t()}
  def allocate(%__MODULE__{current: current}) do
    case increment(current) do
      {:ok, revision} -> {:ok, %__MODULE__{current: revision}, revision}
      :overflow -> overflow()
    end
  end

  defp increment(value) when value < @safe_integer, do: {:ok, value + 1}
  defp increment(_value), do: :overflow

  defp safe_revision?(value), do: is_integer(value) and value in 0..@safe_integer

  defp invalid do
    {:error,
     Failure.new!(
       target: nil,
       stage: :internal,
       code: :contract_violation,
       message: "Retained source revision is invalid"
     )}
  end

  defp overflow do
    {:error,
     Failure.new!(
       target: nil,
       stage: :internal,
       code: :contract_violation,
       message: "Source revision limit was reached"
     )}
  end
end
