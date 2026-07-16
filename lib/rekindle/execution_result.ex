defmodule Rekindle.ExecutionResult do
  @moduledoc "The closed result of executing an external target plan."

  @fields [
    :build_key,
    :outcome,
    :exit_code,
    :signal,
    :duration_ms,
    :stdout_tail,
    :stderr_tail,
    :discarded_bytes,
    :cleanup
  ]

  @enforce_keys @fields
  defstruct [contract_version: 1] ++ @fields

  @type t :: %__MODULE__{
          contract_version: 1,
          build_key: String.t(),
          outcome: atom(),
          exit_code: integer() | nil,
          signal: non_neg_integer() | nil,
          duration_ms: non_neg_integer(),
          stdout_tail: binary(),
          stderr_tail: binary(),
          discarded_bytes: non_neg_integer() | map(),
          cleanup: atom() | map()
        }
end
