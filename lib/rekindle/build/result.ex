defmodule Rekindle.Build.Result do
  @moduledoc """
  The artifact and metadata returned by `Rekindle.build/2`.

  `artifact` is the executable or Web entry selected by the completed build.
  Release builds return the published artifact path. Metadata includes the
  manifest, Cargo package and binary, Rust target, target directory, compiler
  diagnostics, and the Web generation when available.
  """

  @enforce_keys [:target, :profile, :artifact]
  defstruct [:target, :profile, :artifact, metadata: %{}]

  @type t :: %__MODULE__{
          target: :web | :desktop,
          profile: :dev | :release,
          artifact: Path.t(),
          metadata: map()
        }
end
