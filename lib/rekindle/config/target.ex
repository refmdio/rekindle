defmodule Rekindle.Config.Target do
  @moduledoc false

  @enforce_keys [:name, :entry, :features, :profiles]
  defstruct [:name, :entry, :package, :binary, :features, :profiles]

  @type t :: %__MODULE__{
          name: :web | :desktop,
          entry: Path.t(),
          package: String.t() | nil,
          binary: String.t() | nil,
          features: [String.t()],
          profiles: %{dev: String.t(), release: String.t()}
        }
end
