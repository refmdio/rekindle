defmodule Rekindle.SupportLevel do
  @moduledoc false

  @values [:qualified, :experimental, :not_applicable]

  @type t :: :qualified | :experimental | :not_applicable

  @spec values() :: [t()]
  def values, do: @values

  @spec valid?(term()) :: boolean()
  def valid?(value), do: value in @values

  @spec from_string(term()) :: {:ok, t()} | :error
  def from_string("qualified"), do: {:ok, :qualified}
  def from_string("experimental"), do: {:ok, :experimental}
  def from_string("not_applicable"), do: {:ok, :not_applicable}
  def from_string(_value), do: :error

  @spec from_producer(term()) :: {:ok, t()} | :error
  def from_producer(%{"kind" => "extension"}), do: {:ok, :not_applicable}

  def from_producer(%{
        "integration_identity" => %{"capability" => %{"support_level" => value}}
      }),
      do: from_string(value)

  def from_producer(_producer), do: :error
end
