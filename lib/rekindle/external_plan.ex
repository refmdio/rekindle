defmodule Rekindle.ExternalPlan do
  @moduledoc "A closed, replace-environment execution plan returned by a target backend."

  @fields [
    :executable,
    :argv,
    :cwd,
    :env_mode,
    :env_set,
    :diagnostic_mode,
    :timeout_ms,
    :expected_manifest
  ]

  @enforce_keys @fields
  defstruct [contract_version: 1] ++ @fields

  @type cwd :: %{required(:root) => :project | :client | :staging, required(:path) => String.t()}
  @type env_entry :: %{
          required(:name) => String.t(),
          required(:value) => String.t(),
          required(:secret) => boolean()
        }

  @type t :: %__MODULE__{
          contract_version: 1,
          executable: String.t(),
          argv: [String.t()],
          cwd: cwd(),
          env_mode: :replace,
          env_set: [env_entry()],
          diagnostic_mode: :opaque | :cargo_json,
          timeout_ms: pos_integer(),
          expected_manifest: String.t()
        }
end
