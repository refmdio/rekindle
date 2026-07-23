defmodule Rekindle.Toolchain.Check do
  @moduledoc false

  @enforce_keys [:name, :status, :message]
  defstruct [:name, :status, :message]

  @type t :: %__MODULE__{
          name: atom(),
          status: :ok | :changed | :error,
          message: String.t()
        }
end
