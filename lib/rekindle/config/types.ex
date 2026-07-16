defmodule Rekindle.Config.Project do
  @moduledoc "Immutable admitted Rekindle configuration for one OTP application."
  @enforce_keys [:otp_app, :application_id, :project_root, :build, :dev]
  defstruct [:otp_app, :application_id, :project_root, :build, :dev]

  @type t :: %__MODULE__{
          otp_app: Rekindle.otp_app(),
          application_id: String.t(),
          project_root: Path.t(),
          build: Rekindle.Config.BuildConfig.t(),
          dev: Rekindle.Config.DevConfig.t()
        }
end

defmodule Rekindle.Config.BuildConfig do
  @moduledoc false
  @enforce_keys [:schema, :client, :targets, :cache, :process]
  defstruct [:schema, :client, :targets, :cache, :process]

  @type targets :: %{
          optional(:web) => Rekindle.Config.WebTarget.t(),
          optional(:desktop) => Rekindle.Config.DesktopTarget.t()
        }

  @type t :: %__MODULE__{
          schema: 1,
          client: String.t(),
          targets: targets(),
          cache: Rekindle.Config.CachePolicy.t(),
          process: Rekindle.Config.ProcessPolicy.t()
        }
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

  @type backend :: :canonical | {:external, Rekindle.TargetBackend.admission()}
  @type profiles :: %{dev: String.t(), release: String.t()}
  @type projection :: %{mode: :phoenix_static, root: String.t()}

  @type toolchain ::
          %{kind: :rustup, name: String.t()}
          | %{kind: :path, cargo: Path.t(), rustc: Path.t(), identity: String.t()}

  @type t :: %__MODULE__{
          package: String.t(),
          binary: String.t(),
          backend: backend(),
          features: [String.t()],
          profiles: profiles(),
          public: String.t() | nil,
          hot_styles: [String.t()],
          projection: projection(),
          toolchain: toolchain() | nil,
          rust_target: String.t() | nil,
          default_features: boolean() | nil,
          environment: Rekindle.Config.EnvironmentPolicy.t() | nil
        }
end

defmodule Rekindle.Config.DesktopTarget do
  @moduledoc false
  @enforce_keys [:package, :binary, :backend, :features, :profiles, :runtime, :projection]
  defstruct @enforce_keys ++ [:toolchain, :rust_target, :default_features, :environment]

  @type backend :: :canonical | {:external, Rekindle.TargetBackend.admission()}
  @type profiles :: %{dev: String.t(), release: String.t()}
  @type projection :: %{mode: :directory, root: String.t()}

  @type toolchain ::
          %{kind: :rustup, name: String.t()}
          | %{kind: :path, cargo: Path.t(), rustc: Path.t(), identity: String.t()}

  @type runtime :: %{
          readiness: :ipc_v1 | :startup_grace,
          startup_timeout_ms: 100..120_000,
          shutdown_timeout_ms: 100..30_000,
          replacement: :overlap | :replace_before_start,
          handoff: :enabled | :disabled,
          startup_grace_ms: 100..30_000 | nil
        }

  @type t :: %__MODULE__{
          package: String.t(),
          binary: String.t(),
          backend: backend(),
          features: [String.t()],
          profiles: profiles(),
          runtime: runtime(),
          projection: projection(),
          toolchain: toolchain() | nil,
          rust_target: String.t() | nil,
          default_features: boolean() | nil,
          environment: Rekindle.Config.EnvironmentPolicy.t() | nil
        }
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

  @type t :: %__MODULE__{
          build_timeout_ms: 1_000..3_600_000,
          terminate_grace_ms: 0..30_000,
          kill_grace_ms: 100..30_000,
          output_bytes_per_stream: 1_048_576..268_435_456,
          max_cargo_builds: 1..16,
          max_helper_jobs: 1..16
        }
end

defmodule Rekindle.Config.CachePolicy do
  @moduledoc false
  @enforce_keys [:root, :retained_generations, :max_generation_bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          root: String.t(),
          retained_generations: 1..20,
          max_generation_bytes: 67_108_864..17_179_869_184
        }
end

defmodule Rekindle.Config.EnvironmentPolicy do
  @moduledoc false
  @enforce_keys [:inherit, :set, :unset, :build_inputs, :redact, :resolved]
  defstruct @enforce_keys

  @type source :: {:literal | :host, String.t()}
  @type assignment :: {String.t(), source()}
  @type resolved_assignment :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          inherit: :none | :toolchain | :host,
          set: [assignment()],
          unset: [String.t()],
          build_inputs: [String.t()],
          redact: [String.t()],
          resolved: [resolved_assignment()]
        }
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

  @type accepted_origins :: %{
          source: :endpoint | :explicit,
          origins: [String.t()]
        }

  @type t :: %__MODULE__{
          schema: 1,
          enabled: boolean(),
          targets: [Rekindle.target()],
          endpoint: module() | nil,
          accepted_origins: accepted_origins() | nil,
          debounce_ms: 0..2_000,
          diagnostic_limit: 1..4_096,
          browser_message_bytes: 65_536..4_194_304,
          browser_startup_timeout_ms: 1_000..120_000,
          handoff_bytes: 0..16_777_216,
          snapshot_timeout_ms: 100..10_000,
          restore_timeout_ms: 100..10_000
        }
end
