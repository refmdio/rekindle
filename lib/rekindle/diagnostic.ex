defmodule Rekindle.Diagnostic do
  @moduledoc false

  @enforce_keys [:severity, :source, :message]
  defstruct [:severity, :source, :message, :file, :line, :rendered]

  @type t :: %__MODULE__{
          severity: atom(),
          source: atom(),
          message: String.t(),
          file: Path.t() | nil,
          line: pos_integer() | nil,
          rendered: String.t() | nil
        }
end
