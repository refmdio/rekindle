defmodule Rekindle.Config.Error do
  @moduledoc false

  @enforce_keys [:kind, :message]
  defexception [:kind, :message]

  @type t :: %__MODULE__{kind: atom(), message: String.t()}

  @spec new(atom(), String.t()) :: t()
  def new(kind, message), do: %__MODULE__{kind: kind, message: message}
end
