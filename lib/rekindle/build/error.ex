defmodule Rekindle.Build.Error do
  @moduledoc """
  Reports an invalid build target, profile, entry, or invocation.
  """

  @enforce_keys [:kind, :message]
  defexception [:kind, :message]

  @type t :: %__MODULE__{kind: atom(), message: String.t()}

  @spec new(atom(), String.t()) :: t()
  @doc false
  def new(kind, message), do: %__MODULE__{kind: kind, message: message}
end
