defmodule Rekindle.BackendContext do
  @moduledoc "The closed, immutable input passed to a target backend."

  @fields [
    :otp_app,
    :application_id,
    :rekindle_version,
    :project_session,
    :target,
    :package,
    :binary,
    :profile,
    :features,
    :public_root,
    :hot_styles,
    :runtime_manifest,
    :source_revision,
    :project_root,
    :client_root,
    :staging_root,
    :limits,
    :diagnostic_sink,
    :backend_id,
    :backend_version,
    :options_digest
  ]

  @enforce_keys @fields
  defstruct [contract_version: 1] ++ @fields

  @type t :: %__MODULE__{
          contract_version: 1,
          otp_app: atom(),
          application_id: String.t(),
          rekindle_version: String.t(),
          project_session: String.t(),
          target: Rekindle.target(),
          package: String.t(),
          binary: String.t(),
          profile: String.t(),
          features: [String.t()],
          public_root: Rekindle.QualifiedPath.t() | nil,
          hot_styles: [String.t()],
          runtime_manifest: map() | nil,
          source_revision: non_neg_integer(),
          project_root: Rekindle.QualifiedPath.t(),
          client_root: Rekindle.QualifiedPath.t(),
          staging_root: Rekindle.QualifiedPath.t(),
          limits: map(),
          diagnostic_sink: term(),
          backend_id: String.t(),
          backend_version: String.t(),
          options_digest: String.t()
        }
end
