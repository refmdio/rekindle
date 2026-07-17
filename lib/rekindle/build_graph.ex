defmodule Rekindle.BuildGraph do
  @moduledoc false

  @nodes [
    :project_model,
    :cargo_web,
    :cargo_desktop,
    :external_web,
    :external_desktop,
    :bindgen_web,
    :package_web,
    :seal_web,
    :seal_desktop,
    :activate_web,
    :activate_desktop,
    :project_phoenix,
    :project_native
  ]

  @keyed_nodes ~w[cargo_web cargo_desktop external_web external_desktop bindgen_web package_web seal_web seal_desktop]a

  @spec nodes() :: [atom()]
  def nodes, do: @nodes

  @spec keyed_nodes() :: [atom()]
  def keyed_nodes, do: @keyed_nodes

  @spec order(atom()) :: {:ok, non_neg_integer()} | :error
  def order(node) do
    case Enum.find_index(@nodes, &(&1 == node)) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  @spec target_inputs(Rekindle.BuildGraph.Inventory.t(), [Rekindle.target()]) ::
          {:ok, %{required(Rekindle.target()) => [map()]}} | {:error, Rekindle.Failure.t()}
  def target_inputs(%Rekindle.BuildGraph.Inventory{} = inventory, targets)
      when is_list(targets) do
    if targets != [] and targets == targets |> Enum.uniq() |> Enum.sort_by(&target_rank/1) and
         Enum.all?(targets, &(&1 in [:desktop, :web])) do
      {:ok, Map.new(targets, &{&1, inventory.direct_inputs})}
    else
      invalid_targets()
    end
  end

  def target_inputs(_inventory, _targets), do: invalid_targets()

  defp target_rank(:web), do: 0
  defp target_rank(:desktop), do: 1
  defp target_rank(_target), do: 2

  defp invalid_targets do
    {:error,
     Rekindle.Failure.new!(
       target: nil,
       stage: :internal,
       code: :contract_violation,
       message: "Build graph target inventory is invalid"
     )}
  end
end
