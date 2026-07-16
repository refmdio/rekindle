defmodule Rekindle.Config.Project do
  @moduledoc "Immutable admitted Rekindle configuration for one OTP application."
  @enforce_keys [:otp_app, :application_id, :project_root, :build, :dev]
  defstruct [:otp_app, :application_id, :project_root, :build, :dev]
end

defmodule Rekindle.Config.BuildConfig do
  @moduledoc false
  @enforce_keys [:schema, :client, :targets, :cache, :process]
  defstruct [:schema, :client, :targets, :cache, :process]
end

defmodule Rekindle.Config.WebTarget do
  @moduledoc false
  @enforce_keys [
    :package,
    :binary,
    :backend,
    :features,
    :profiles,
    :public,
    :hot_styles,
    :projection
  ]
  defstruct @enforce_keys ++ [:toolchain, :rust_target, :default_features, :environment]
end

defmodule Rekindle.Config.DesktopTarget do
  @moduledoc false
  @enforce_keys [:package, :binary, :backend, :features, :profiles, :runtime, :projection]
  defstruct @enforce_keys ++ [:toolchain, :rust_target, :default_features, :environment]
end

defmodule Rekindle.Config.ProcessPolicy do
  @moduledoc false
  @enforce_keys [
    :build_timeout_ms,
    :terminate_grace_ms,
    :kill_grace_ms,
    :output_bytes_per_stream,
    :max_cargo_builds,
    :max_helper_jobs
  ]
  defstruct @enforce_keys
end

defmodule Rekindle.Config.CachePolicy do
  @moduledoc false
  @enforce_keys [:root, :retained_generations, :max_generation_bytes]
  defstruct @enforce_keys
end

defmodule Rekindle.Config.EnvironmentPolicy do
  @moduledoc false
  @enforce_keys [:inherit, :set, :unset, :build_inputs, :redact, :resolved]
  defstruct @enforce_keys
end

defmodule Rekindle.Config.DevConfig do
  @moduledoc false
  @enforce_keys [
    :schema,
    :enabled,
    :targets,
    :endpoint,
    :accepted_origins,
    :debounce_ms,
    :diagnostic_limit,
    :browser_message_bytes,
    :browser_startup_timeout_ms,
    :handoff_bytes,
    :snapshot_timeout_ms,
    :restore_timeout_ms
  ]
  defstruct @enforce_keys
end
