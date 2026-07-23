defmodule Rekindle.Toolchain.Error do
  @moduledoc false

  @enforce_keys [:kind, :message]
  defexception [:kind, :message, output: ""]

  @type t :: %__MODULE__{kind: atom(), message: String.t(), output: String.t()}

  @spec new(atom(), String.t(), keyword()) :: t()
  def new(kind, message, options \\ []) do
    struct!(__MODULE__, Keyword.merge([kind: kind, message: message], options))
  end
end
