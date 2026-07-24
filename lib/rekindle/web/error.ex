defmodule Rekindle.Web.Error do
  @moduledoc """
  Reports Web packaging, manifest validation, or publication failures.
  """

  @enforce_keys [:kind, :message]
  defexception [:kind, :message, output: ""]

  @type t :: %__MODULE__{
          kind: atom(),
          message: String.t(),
          output: String.t()
        }

  @spec new(atom(), String.t(), keyword()) :: t()
  @doc false
  def new(kind, message, options \\ []) do
    struct!(__MODULE__, Keyword.merge([kind: kind, message: message], options))
  end
end
