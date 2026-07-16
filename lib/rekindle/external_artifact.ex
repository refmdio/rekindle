defmodule Rekindle.ExternalArtifact do
  @moduledoc "The single manifest selected by a target backend after execution."

  alias Rekindle.Diagnostic

  @enforce_keys [:manifest, :supplemental_diagnostics]
  defstruct contract_version: 1, manifest: nil, supplemental_diagnostics: nil

  @type t :: %__MODULE__{
          contract_version: 1,
          manifest: String.t(),
          supplemental_diagnostics: [Diagnostic.t()]
        }
end
