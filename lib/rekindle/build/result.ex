defmodule Rekindle.Build.Result do
  @moduledoc false

  @enforce_keys [:target, :profile, :artifact]
  defstruct [:target, :profile, :artifact, metadata: %{}]

  @type t :: %__MODULE__{
          target: :web | :desktop,
          profile: :dev | :release,
          artifact: Path.t(),
          metadata: map()
        }
end
