defmodule Rekindle.Config do
  @moduledoc "Closed v1 Mix configuration admission and normalization."

  alias Rekindle.Config.{
    BuildConfig,
    CachePolicy,
    DesktopTarget,
    DevConfig,
    EnvironmentPolicy,
    ProcessPolicy,
    Project,
    WebTarget
  }

  alias Rekindle.{ConfigError, TargetBackend}

  @build_keys ~w[schema client targets cache process]a
  @cache_keys ~w[root retained_generations max_generation_bytes]a
  @process_keys ~w[build_timeout_ms terminate_grace_ms kill_grace_ms output_bytes_per_stream max_cargo_builds max_helper_jobs]a
  @common_target_keys ~w[package binary toolchain rust_target features default_features profiles environment projection backend]a
  @web_keys @common_target_keys ++ ~w[public hot_styles]a
  @desktop_keys @common_target_keys ++ ~w[runtime]a
  @environment_keys ~w[inherit set unset build_inputs redact]a
  @toolchain_keys ~w[kind name cargo rustc identity]a
  @profiles_keys ~w[dev release]a
  @runtime_keys ~w[readiness startup_timeout_ms shutdown_timeout_ms replacement handoff startup_grace_ms]a
  @projection_keys ~w[mode root]a
  @dev_keys ~w[schema enabled targets endpoint accepted_origins debounce_ms diagnostic_limit browser_message_bytes browser_startup_timeout_ms handoff_bytes snapshot_timeout_ms restore_timeout_ms]a

  @default_cache [
    root: ".rekindle/cache",
    retained_generations: 3,
    max_generation_bytes: 2_147_483_648
  ]
  @default_process [
    build_timeout_ms: 900_000,
    terminate_grace_ms: 3_000,
    kill_grace_ms: 2_000,
    output_bytes_per_stream: 16_777_216,
    max_cargo_builds: 2,
    max_helper_jobs: 4
  ]
  @default_environment [inherit: :toolchain, set: [], unset: [], build_inputs: [], redact: []]
  @default_profiles [dev: "dev", release: "release"]
  @default_runtime [
    readiness: :ipc_v1,
    startup_timeout_ms: 10_000,
    shutdown_timeout_ms: 3_000,
    replacement: :overlap,
    handoff: :enabled
  ]
  @default_dev [
    schema: 1,
    enabled: true,
    accepted_origins: :endpoint,
    debounce_ms: 75,
    diagnostic_limit: 512,
    browser_message_bytes: 1_048_576,
    browser_startup_timeout_ms: 15_000,
    handoff_bytes: 1_048_576,
    snapshot_timeout_ms: 1_000,
    restore_timeout_ms: 1_000
  ]

  @spec load(atom(), keyword()) :: {:ok, Project.t()} | {:error, [ConfigError.t()]}
  def load(otp_app, options \\ []) when is_atom(otp_app) do
    build = Application.get_env(otp_app, :rekindle_build)
    dev = Application.get_env(otp_app, :rekindle_dev, [])
    normalize(otp_app, build, dev, options)
  end

  @spec normalize(atom(), keyword() | nil, keyword(), keyword()) ::
          {:ok, Project.t()} | {:error, [ConfigError.t()]}
  def normalize(otp_app, build, dev \\ [], options \\ [])

  def normalize(otp_app, build, dev, options)
      when is_atom(otp_app) and is_list(options) do
    with {:ok, project_root} <- project_root(options),
         {:ok, application_id} <- application_id(otp_app),
         {:ok, build} <- normalize_build(build),
         {:ok, dev} <- normalize_dev(dev, build, otp_app),
         :ok <- validate_path_ownership(build, project_root) do
      {:ok,
       %Project{
         otp_app: otp_app,
         application_id: application_id,
         project_root: project_root,
         build: build,
         dev: dev
       }}
    else
      {:error, %ConfigError{} = error} -> {:error, [error]}
      {:error, errors} when is_list(errors) -> {:error, errors}
    end
  end

  def normalize(_otp_app, _build, _dev, _options),
    do: errors([], :config_invalid, "invalid configuration input")

  defp project_root(options) do
    case Keyword.fetch(options, :project_root) do
      {:ok, value} -> normalize_project_root(value)
      :error -> File.cwd() |> normalize_cwd()
    end
  rescue
    _ -> error([:project_root], :path_invalid, "project root is invalid")
  end

  defp normalize_cwd({:ok, value}), do: normalize_project_root(value)

  defp normalize_cwd({:error, _reason}),
    do: error([:project_root], :path_invalid, "project root is unavailable")

  defp normalize_project_root(value) when is_binary(value) do
    if value != "" and byte_size(value) <= 4_096 and String.valid?(value) and
         String.normalize(value, :nfc) == value and not String.contains?(value, <<0>>) and
         not Regex.match?(~r/[\x00-\x1F\x7F]/, value) do
      expanded = Path.expand(value)

      if byte_size(expanded) <= 4_096 and Path.dirname(expanded) != expanded and
           match?({:ok, %{type: :directory}}, File.lstat(expanded)) do
        {:ok, expanded}
      else
        error([:project_root], :path_invalid, "project root must be an existing safe directory")
      end
    else
      error([:project_root], :path_invalid, "project root is invalid")
    end
  end

  defp normalize_project_root(_value),
    do: error([:project_root], :path_invalid, "project root is invalid")

  defp normalize_build(nil),
    do: error([:rekindle_build], :config_missing, "rekindle_build is required")

  defp normalize_build(build) do
    with :ok <- closed_keyword(build, @build_keys, [:rekindle_build]),
         :ok <- exact(Map.new(build)[:schema], 1, [:rekindle_build, :schema]),
         {:ok, client} <- relative_path(fetch(build, :client), [:rekindle_build, :client]),
         {:ok, targets} <- normalize_targets(fetch(build, :targets)),
         {:ok, cache} <- normalize_cache(Keyword.get(build, :cache, @default_cache)),
         {:ok, process} <- normalize_process(Keyword.get(build, :process, @default_process)) do
      {:ok,
       %BuildConfig{schema: 1, client: client, targets: targets, cache: cache, process: process}}
    end
  end

  defp normalize_targets(targets) do
    with :ok <- closed_keyword(targets, [:web, :desktop], [:rekindle_build, :targets]),
         :ok <- nonempty(targets, [:rekindle_build, :targets]) do
      Enum.reduce_while(targets, {:ok, %{}}, fn
        {:web, config}, {:ok, acc} ->
          continue_target(normalize_web(config), :web, acc)

        {:desktop, config}, {:ok, acc} ->
          continue_target(normalize_desktop(config), :desktop, acc)
      end)
    end
  end

  defp continue_target({:ok, target}, name, acc), do: {:cont, {:ok, Map.put(acc, name, target)}}
  defp continue_target({:error, _} = error, _name, _acc), do: {:halt, error}

  defp normalize_web(config) do
    path = [:rekindle_build, :targets, :web]

    with :ok <- closed_keyword(config, @web_keys, path),
         {:ok, common} <- normalize_target_common(:web, config, path),
         :ok <- validate_web_rust_target(common, path),
         {:ok, public} <- optional_path(Keyword.get(config, :public), path ++ [:public]),
         {:ok, hot_styles} <-
           normalized_paths(Keyword.get(config, :hot_styles, []), path ++ [:hot_styles]),
         :ok <- styles_below_public(hot_styles, public, path),
         {:ok, projection} <- normalize_projection(:web, fetch(config, :projection), path) do
      {:ok,
       struct!(
         WebTarget,
         common
         |> Map.merge(%{public: public, hot_styles: hot_styles, projection: projection})
       )}
    end
  end

  defp normalize_desktop(config) do
    path = [:rekindle_build, :targets, :desktop]

    with :ok <- closed_keyword(config, @desktop_keys, path),
         {:ok, common} <- normalize_target_common(:desktop, config, path),
         {:ok, runtime} <-
           normalize_runtime(Keyword.get(config, :runtime, @default_runtime), path),
         {:ok, projection} <- normalize_projection(:desktop, fetch(config, :projection), path) do
      {:ok,
       struct!(DesktopTarget, common |> Map.merge(%{runtime: runtime, projection: projection}))}
    end
  end

  defp normalize_target_common(target, config, path) do
    with {:ok, package} <- identifier(fetch(config, :package), path ++ [:package]),
         {:ok, binary} <- identifier(fetch(config, :binary), path ++ [:binary]),
         {:ok, features} <- identifiers(Keyword.get(config, :features, []), path ++ [:features]),
         {:ok, profiles} <-
           normalize_profiles(Keyword.get(config, :profiles, @default_profiles), path),
         {:ok, backend} <- normalize_backend(target, Keyword.get(config, :backend), path),
         {:ok, canonical} <- normalize_pipeline(config, backend, path) do
      {:ok,
       canonical
       |> Map.merge(%{
         package: package,
         binary: binary,
         backend: backend,
         features: features,
         profiles: profiles
       })}
    end
  end

  defp normalize_backend(_target, nil, _path), do: {:ok, :canonical}

  defp normalize_backend(target, backend, path) do
    with :ok <- closed_keyword(backend, [:module, :options], path ++ [:backend]),
         module when is_atom(module) <- fetch(backend, :module),
         {:ok, admission} <-
           TargetBackend.admit(module, target, Keyword.get(backend, :options, %{})) do
      {:ok, {:external, admission}}
    else
      {:error, errors} when is_list(errors) ->
        {:error, errors}

      _ ->
        error(
          path ++ [:backend, :module],
          :config_invalid,
          "backend module must be an existing atom"
        )
    end
  end

  defp normalize_pipeline(config, :canonical, path) do
    with {:ok, toolchain} <- normalize_toolchain(fetch(config, :toolchain), path),
         {:ok, rust_target} <-
           optional_identifier(Keyword.get(config, :rust_target), path ++ [:rust_target]),
         {:ok, default_features} <-
           boolean(Keyword.get(config, :default_features, true), path ++ [:default_features]),
         {:ok, environment} <-
           normalize_environment(Keyword.get(config, :environment, @default_environment), path) do
      {:ok,
       %{
         toolchain: toolchain,
         rust_target: rust_target,
         default_features: default_features,
         environment: environment
       }}
    end
  end

  defp normalize_pipeline(config, {:external, _admission}, path) do
    forbidden = [:toolchain, :rust_target, :default_features, :environment]

    if Enum.any?(forbidden, &Keyword.has_key?(config, &1)) do
      error(path, :config_invalid, "external backend cannot mix canonical pipeline fields")
    else
      {:ok, %{toolchain: nil, rust_target: nil, default_features: nil, environment: nil}}
    end
  end

  defp normalize_toolchain(toolchain, path) do
    with :ok <- closed_keyword(toolchain, @toolchain_keys, path ++ [:toolchain]) do
      case Keyword.get(toolchain, :kind) do
        :rustup ->
          with :ok <- exact_keys(toolchain, [:kind, :name], path ++ [:toolchain]),
               {:ok, name} <- identifier(fetch(toolchain, :name), path ++ [:toolchain, :name]) do
            {:ok, %{kind: :rustup, name: name}}
          end

        :path ->
          with :ok <-
                 exact_keys(toolchain, [:kind, :cargo, :rustc, :identity], path ++ [:toolchain]),
               {:ok, cargo} <-
                 absolute_path(fetch(toolchain, :cargo), path ++ [:toolchain, :cargo]),
               {:ok, rustc} <-
                 absolute_path(fetch(toolchain, :rustc), path ++ [:toolchain, :rustc]),
               {:ok, identity} <-
                 identifier(fetch(toolchain, :identity), path ++ [:toolchain, :identity]) do
            {:ok, %{kind: :path, cargo: cargo, rustc: rustc, identity: identity}}
          end

        _ ->
          error(
            path ++ [:toolchain, :kind],
            :config_invalid,
            "toolchain kind must be rustup or path"
          )
      end
    end
  end

  defp normalize_profiles(value, path) do
    with :ok <- closed_keyword(value, @profiles_keys, path ++ [:profiles]),
         {:ok, dev} <- identifier(Keyword.get(value, :dev, "dev"), path ++ [:profiles, :dev]),
         {:ok, release} <-
           identifier(Keyword.get(value, :release, "release"), path ++ [:profiles, :release]) do
      {:ok, %{dev: dev, release: release}}
    end
  end

  defp normalize_environment(value, path) do
    with :ok <- closed_keyword(value, @environment_keys, path ++ [:environment]),
         {:ok, inherit} <-
           member(
             Keyword.get(value, :inherit, :toolchain),
             [:none, :toolchain, :host],
             path ++ [:environment, :inherit]
           ),
         {:ok, set} <- normalize_env_set(Keyword.get(value, :set, []), path),
         {:ok, unset} <- env_names(Keyword.get(value, :unset, []), path ++ [:environment, :unset]),
         {:ok, build_inputs} <-
           env_names(Keyword.get(value, :build_inputs, []), path ++ [:environment, :build_inputs]),
         {:ok, redact} <-
           env_names(Keyword.get(value, :redact, []), path ++ [:environment, :redact]),
         :ok <- validate_env_sets(set, build_inputs, redact, path) do
      {:ok,
       %EnvironmentPolicy{
         inherit: inherit,
         set: set,
         unset: unset,
         build_inputs: build_inputs,
         redact: redact
       }}
    end
  end

  defp normalize_env_set(value, path) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn
      {name, {origin, source}}, {:ok, acc}
      when origin in [:literal, :host] and is_binary(source) ->
        with {:ok, name} <- env_name(name, path ++ [:environment, :set]),
             :ok <- safe_string(source, path ++ [:environment, :set, name]) do
          {:cont, {:ok, [{name, {origin, source}} | acc]}}
        else
          {:error, _} = error -> {:halt, error}
        end

      _, _ ->
        {:halt,
         error(path ++ [:environment, :set], :config_invalid, "invalid environment set entry")}
    end)
    |> then(fn
      {:ok, entries} ->
        unique_sorted(Enum.reverse(entries), &elem(&1, 0), path ++ [:environment, :set])

      error ->
        error
    end)
  end

  defp normalize_env_set(_value, path),
    do: error(path ++ [:environment, :set], :config_invalid, "environment set must be a list")

  defp validate_env_sets(set, build_inputs, redact, path) do
    names = MapSet.new(Enum.map(set, &elem(&1, 0)))

    cond do
      not MapSet.subset?(names, MapSet.new(build_inputs)) ->
        error(
          path ++ [:environment, :build_inputs],
          :config_invalid,
          "every set variable must be a build input"
        )

      Enum.any?(set, fn {name, {origin, _}} -> origin == :host and name not in redact end) ->
        error(
          path ++ [:environment, :redact],
          :config_invalid,
          "host-sourced set variables must be redacted"
        )

      true ->
        :ok
    end
  end

  defp normalize_projection(target, value, path) do
    with :ok <- closed_keyword(value, @projection_keys, path ++ [:projection]),
         {:ok, mode} <-
           member(fetch(value, :mode), projection_modes(target), path ++ [:projection, :mode]),
         {:ok, root} <- relative_path(fetch(value, :root), path ++ [:projection, :root]) do
      {:ok, %{mode: mode, root: root}}
    end
  end

  defp projection_modes(:web), do: [:phoenix_static]
  defp projection_modes(:desktop), do: [:directory]

  defp normalize_runtime(value, path) do
    with :ok <- closed_keyword(value, @runtime_keys, path ++ [:runtime]),
         {:ok, readiness} <-
           member(
             Keyword.get(value, :readiness, :ipc_v1),
             [:ipc_v1, :startup_grace],
             path ++ [:runtime, :readiness]
           ),
         {:ok, startup_timeout} <-
           positive(
             Keyword.get(value, :startup_timeout_ms, 10_000),
             path ++ [:runtime, :startup_timeout_ms]
           ),
         {:ok, shutdown_timeout} <-
           positive(
             Keyword.get(value, :shutdown_timeout_ms, 3_000),
             path ++ [:runtime, :shutdown_timeout_ms]
           ),
         {:ok, replacement} <-
           member(
             Keyword.get(value, :replacement, :overlap),
             [:overlap, :replace_before_start],
             path ++ [:runtime, :replacement]
           ),
         {:ok, handoff} <-
           member(
             Keyword.get(value, :handoff, :enabled),
             [:enabled, :disabled],
             path ++ [:runtime, :handoff]
           ),
         {:ok, startup_grace} <-
           optional_positive(
             Keyword.get(value, :startup_grace_ms),
             path ++ [:runtime, :startup_grace_ms]
           ),
         :ok <- validate_runtime(readiness, replacement, handoff, startup_grace, path) do
      {:ok,
       %{
         readiness: readiness,
         startup_timeout_ms: startup_timeout,
         shutdown_timeout_ms: shutdown_timeout,
         replacement: replacement,
         handoff: handoff,
         startup_grace_ms: startup_grace
       }}
    end
  end

  defp validate_runtime(:startup_grace, _replacement, :disabled, grace, _path)
       when is_integer(grace), do: :ok

  defp validate_runtime(:ipc_v1, :overlap, _handoff, nil, _path), do: :ok
  defp validate_runtime(:ipc_v1, :replace_before_start, :disabled, nil, _path), do: :ok

  defp validate_runtime(_, _, _, _, path),
    do: error(path ++ [:runtime], :config_invalid, "incompatible desktop runtime fields")

  defp normalize_cache(value) do
    with :ok <- closed_keyword(value, @cache_keys, [:rekindle_build, :cache]) do
      value = Keyword.merge(@default_cache, value)

      normalize_cache_values(value)
    end
  end

  defp normalize_cache_values(value) do
    with {:ok, root} <-
           relative_path(fetch(value, :root), [:rekindle_build, :cache, :root]),
         {:ok, retained} <-
           nonnegative(fetch(value, :retained_generations), [
             :rekindle_build,
             :cache,
             :retained_generations
           ]),
         {:ok, max_bytes} <-
           positive(fetch(value, :max_generation_bytes), [
             :rekindle_build,
             :cache,
             :max_generation_bytes
           ]) do
      {:ok,
       %CachePolicy{root: root, retained_generations: retained, max_generation_bytes: max_bytes}}
    end
  end

  defp normalize_process(value) do
    with :ok <- closed_keyword(value, @process_keys, [:rekindle_build, :process]) do
      value = Keyword.merge(@default_process, value)

      normalize_process_values(value)
    end
  end

  defp normalize_process_values(value) do
    with {:ok, build_timeout} <-
           positive(fetch(value, :build_timeout_ms), [
             :rekindle_build,
             :process,
             :build_timeout_ms
           ]),
         {:ok, terminate_grace} <-
           positive(fetch(value, :terminate_grace_ms), [
             :rekindle_build,
             :process,
             :terminate_grace_ms
           ]),
         {:ok, kill_grace} <-
           positive(fetch(value, :kill_grace_ms), [:rekindle_build, :process, :kill_grace_ms]),
         {:ok, output_bytes} <-
           positive(fetch(value, :output_bytes_per_stream), [
             :rekindle_build,
             :process,
             :output_bytes_per_stream
           ]),
         {:ok, max_cargo} <-
           positive(fetch(value, :max_cargo_builds), [
             :rekindle_build,
             :process,
             :max_cargo_builds
           ]),
         {:ok, max_helper} <-
           positive(fetch(value, :max_helper_jobs), [:rekindle_build, :process, :max_helper_jobs]) do
      {:ok,
       %ProcessPolicy{
         build_timeout_ms: build_timeout,
         terminate_grace_ms: terminate_grace,
         kill_grace_ms: kill_grace,
         output_bytes_per_stream: output_bytes,
         max_cargo_builds: max_cargo,
         max_helper_jobs: max_helper
       }}
    end
  end

  defp normalize_dev(value, build, otp_app) do
    default_targets = if Map.has_key?(build.targets, :web), do: [:web], else: [:desktop]
    path = [:rekindle_dev]

    with :ok <- closed_keyword(value, @dev_keys, path) do
      value = Keyword.merge(@default_dev ++ [targets: default_targets], value)
      normalize_dev_values(value, build, otp_app, path)
    end
  end

  defp normalize_dev_values(value, build, otp_app, path) do
    with :ok <- exact(fetch(value, :schema), 1, path ++ [:schema]),
         {:ok, enabled} <- boolean(fetch(value, :enabled), path ++ [:enabled]),
         {:ok, targets} <- dev_targets(fetch(value, :targets), build, path),
         {:ok, endpoint} <- endpoint(Keyword.get(value, :endpoint), targets, path),
         {:ok, origins} <-
           origins(fetch(value, :accepted_origins), targets, endpoint, otp_app, path),
         {:ok, debounce} <- nonnegative(fetch(value, :debounce_ms), path ++ [:debounce_ms]),
         {:ok, diagnostic_limit} <-
           positive(fetch(value, :diagnostic_limit), path ++ [:diagnostic_limit]),
         {:ok, browser_bytes} <-
           positive(fetch(value, :browser_message_bytes), path ++ [:browser_message_bytes]),
         {:ok, browser_timeout} <-
           positive(
             fetch(value, :browser_startup_timeout_ms),
             path ++ [:browser_startup_timeout_ms]
           ),
         {:ok, handoff_bytes} <-
           nonnegative(fetch(value, :handoff_bytes), path ++ [:handoff_bytes]),
         {:ok, snapshot_timeout} <-
           positive(fetch(value, :snapshot_timeout_ms), path ++ [:snapshot_timeout_ms]),
         {:ok, restore_timeout} <-
           positive(fetch(value, :restore_timeout_ms), path ++ [:restore_timeout_ms]) do
      {:ok,
       %DevConfig{
         schema: 1,
         enabled: enabled,
         targets: targets,
         endpoint: endpoint,
         accepted_origins: origins,
         debounce_ms: debounce,
         diagnostic_limit: diagnostic_limit,
         browser_message_bytes: browser_bytes,
         browser_startup_timeout_ms: browser_timeout,
         handoff_bytes: handoff_bytes,
         snapshot_timeout_ms: snapshot_timeout,
         restore_timeout_ms: restore_timeout
       }}
    end
  end

  defp dev_targets(value, build, path) do
    with {:ok, targets} <- unique_sorted(value, & &1, path ++ [:targets]),
         :ok <- nonempty(targets, path ++ [:targets]) do
      if Enum.all?(targets, &(&1 in [:web, :desktop] and Map.has_key?(build.targets, &1))) do
        {:ok, targets}
      else
        error(path ++ [:targets], :target_undeclared, "development target is not declared")
      end
    end
  end

  defp endpoint(value, targets, path) do
    cond do
      :web in targets and is_atom(value) and value not in [nil, true, false] ->
        {:ok, value}

      :web in targets ->
        error(path ++ [:endpoint], :config_missing, "Web development requires an endpoint module")

      is_nil(value) ->
        {:ok, nil}

      true ->
        error(path ++ [:endpoint], :config_invalid, "desktop-only development forbids endpoint")
    end
  end

  defp origins(:endpoint, targets, _endpoint, _otp_app, _path),
    do: {:ok, if(:web in targets, do: :endpoint, else: nil)}

  defp origins(value, targets, endpoint, otp_app, path) when is_list(value) do
    if :web in targets do
      with :ok <- nonempty(value, path ++ [:accepted_origins]),
           {:ok, normalized} <- normalize_origins(value, path),
           :ok <- intersects_endpoint_policy(normalized, otp_app, endpoint, path) do
        {:ok, normalized}
      else
        _ -> error(path ++ [:accepted_origins], :config_invalid, "accepted origins are invalid")
      end
    else
      {:ok, nil}
    end
  end

  defp origins(_value, targets, _endpoint, _otp_app, path) do
    if :web in targets do
      error(path ++ [:accepted_origins], :config_invalid, "accepted origins are invalid")
    else
      {:ok, nil}
    end
  end

  defp normalize_origins(values, path) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_origin(value) do
        {:ok, origin} ->
          {:cont, {:ok, [origin | acc]}}

        :error ->
          {:halt,
           error(path ++ [:accepted_origins], :config_invalid, "accepted origins are invalid")}
      end
    end)
    |> then(fn
      {:ok, origins} -> unique_sorted(Enum.reverse(origins), & &1, path ++ [:accepted_origins])
      error -> error
    end)
  end

  defp normalize_origin(value) when is_binary(value) do
    uri = URI.parse(value)

    if String.downcase(uri.scheme || "") in ["http", "https"] and is_binary(uri.host) and
         uri.host != "" and uri.path in [nil, ""] and is_nil(uri.query) and
         is_nil(uri.fragment) do
      scheme = String.downcase(uri.scheme)
      host = String.downcase(uri.host)

      default_port? =
        (scheme == "https" and uri.port in [nil, 443]) or
          (scheme == "http" and uri.port in [nil, 80])

      port = if default_port?, do: "", else: ":#{uri.port}"
      {:ok, "#{scheme}://#{host}#{port}"}
    else
      :error
    end
  end

  defp normalize_origin(_), do: :error

  defp intersects_endpoint_policy(origins, otp_app, endpoint, path) do
    policy = Application.get_env(otp_app, endpoint, []) |> Keyword.get(:check_origin)

    cond do
      policy == false ->
        :ok

      is_list(policy) ->
        if Enum.any?(origins, fn origin -> Enum.any?(policy, &policy_allows?(&1, origin)) end),
          do: :ok,
          else:
            error(
              path ++ [:accepted_origins],
              :config_invalid,
              "accepted origins do not intersect endpoint policy"
            )

      true ->
        error(
          path ++ [:accepted_origins],
          :config_invalid,
          "accepted origins do not intersect endpoint policy"
        )
    end
  end

  defp policy_allows?(pattern, origin) when is_binary(pattern) do
    origin_uri = URI.parse(origin)
    scheme_optional? = String.starts_with?(pattern, "//")
    policy_uri = URI.parse(if(scheme_optional?, do: "http:" <> pattern, else: pattern))
    policy_host = String.downcase(policy_uri.host || "")
    origin_host = String.downcase(origin_uri.host || "")

    host_matches? =
      if String.starts_with?(policy_host, "*.") do
        suffix = String.trim_leading(policy_host, "*")
        String.ends_with?(origin_host, suffix) or origin_host == String.trim_leading(suffix, ".")
      else
        origin_host == policy_host
      end

    scheme_matches? =
      scheme_optional? or String.downcase(policy_uri.scheme || "") == origin_uri.scheme

    explicit_port? = Regex.match?(~r/:\d+\z/, policy_uri.authority || "")

    port_matches? =
      (scheme_optional? and not explicit_port?) or policy_uri.port == origin_uri.port

    host_matches? and scheme_matches? and port_matches?
  end

  defp policy_allows?(_pattern, _origin), do: false

  defp validate_web_rust_target(
         %{backend: :canonical, rust_target: "wasm32-unknown-unknown"},
         _path
       ),
       do: :ok

  defp validate_web_rust_target(%{backend: {:external, _}}, _path), do: :ok

  defp validate_web_rust_target(_common, path),
    do:
      error(
        path ++ [:rust_target],
        :config_invalid,
        "canonical Web target requires wasm32-unknown-unknown"
      )

  defp styles_below_public([], _public, _path), do: :ok

  defp styles_below_public(_styles, nil, path),
    do: error(path ++ [:hot_styles], :config_invalid, "hot styles require a public root")

  defp styles_below_public(styles, public, path) do
    if Enum.all?(styles, &descendant_or_equal?(Path.join(public, &1), public)) do
      :ok
    else
      error(path ++ [:hot_styles], :path_invalid, "hot styles must remain below public")
    end
  end

  defp validate_path_ownership(build, project_root) do
    sources =
      [build.client] ++
        Enum.flat_map(build.targets, fn {_name, target} ->
          if Map.get(target, :public), do: [target.public], else: []
        end)

    outputs =
      [build.cache.root] ++
        Enum.map(build.targets, fn {_name, target} -> target.projection.root end)

    folded_sources = Enum.map(sources, &path_fold/1)
    folded_outputs = Enum.map(outputs, &path_fold/1)

    conflict =
      Enum.find(folded_outputs, fn output ->
        Enum.any?(folded_sources, &overlap?(output, &1)) or
          Enum.count(folded_outputs, &overlap?(output, &1)) > 1
      end)

    with true <- is_nil(conflict),
         :ok <- reject_reserved_sources(sources),
         :ok <- reject_normalization_collisions(sources ++ outputs),
         :ok <- require_source_directories(project_root, sources),
         :ok <- reject_symlink_components(project_root, sources ++ outputs) do
      :ok
    else
      false -> error([:rekindle_build], :path_overlap, "source and output roots overlap unsafely")
      {:error, _} = error -> error
    end
  end

  defp reject_reserved_sources(sources) do
    reserved =
      Enum.map([".git", ".rekindle", "_build", "deps", "dist", "priv/static"], &path_fold/1)

    if Enum.any?(sources, fn source ->
         folded = path_fold(source)
         Enum.any?(reserved, &descendant_or_equal?(folded, &1))
       end),
       do: error([:rekindle_build], :path_invalid, "source root is reserved or generated"),
       else: :ok
  end

  defp reject_normalization_collisions(paths) do
    folded = Enum.map(paths, &path_fold/1)

    if length(folded) == MapSet.size(MapSet.new(folded)),
      do: :ok,
      else:
        error(
          [:rekindle_build],
          :path_overlap,
          "configured roots collide after normalization or case folding"
        )
  end

  defp path_fold(path), do: path |> String.normalize(:nfkc) |> String.downcase()

  defp require_source_directories(project_root, sources) do
    valid? =
      Enum.all?(sources, fn source ->
        case File.lstat(Path.join(project_root, source)) do
          {:ok, %{type: :directory}} -> true
          _ -> false
        end
      end)

    if valid?,
      do: :ok,
      else: error([:rekindle_build], :path_invalid, "source roots must be existing directories")
  end

  defp reject_symlink_components(project_root, paths) do
    project_root = Path.expand(project_root)

    unsafe_root? =
      case File.lstat(project_root) do
        {:ok, %{type: :directory}} ->
          project_root
          |> absolute_components()
          |> Enum.any?(fn path ->
            case File.lstat(path) do
              {:ok, %{type: :symlink}} -> true
              {:ok, _stat} -> false
              {:error, _} -> true
            end
          end)

        _ ->
          true
      end

    unsafe_child? =
      Enum.any?(paths, fn relative ->
        relative
        |> String.split("/")
        |> Enum.scan(project_root, &Path.join(&2, &1))
        |> Enum.any?(fn path ->
          case File.lstat(path) do
            {:ok, %{type: :directory}} -> false
            {:ok, _other} -> true
            {:error, :enoent} -> false
            {:error, _} -> true
          end
        end)
      end)

    if unsafe_root? or unsafe_child?,
      do: error([:rekindle_build], :path_invalid, "configured root traverses a symlink"),
      else: :ok
  end

  defp absolute_components(path) do
    path
    |> Path.split()
    |> Enum.reduce({[], nil}, fn
      "/", {paths, _current} ->
        {["/" | paths], "/"}

      segment, {paths, current} ->
        next =
          if current in [nil, "/"], do: Path.join("/", segment), else: Path.join(current, segment)

        {[next | paths], next}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp overlap?(left, right),
    do: descendant_or_equal?(left, right) or descendant_or_equal?(right, left)

  defp descendant_or_equal?(path, root),
    do: path == root or String.starts_with?(path, root <> "/")

  defp application_id(otp_app) do
    value = Atom.to_string(otp_app)

    if Regex.match?(~r/\A[a-z][a-z0-9_-]{0,127}\z/, value),
      do: {:ok, value},
      else:
        error([:otp_app], :config_invalid, "OTP application cannot form a stable application ID")
  end

  defp closed_keyword(value, allowed, path) when is_list(value) do
    if Keyword.keyword?(value) do
      keys = Keyword.keys(value)

      cond do
        length(keys) != MapSet.size(MapSet.new(keys)) ->
          error(path, :config_invalid, "duplicate configuration key")

        Enum.any?(keys, &(&1 not in allowed)) ->
          error(path, :config_invalid, "unknown configuration key")

        true ->
          :ok
      end
    else
      error(path, :config_invalid, "configuration record must be a keyword list")
    end
  end

  defp closed_keyword(_value, _allowed, path),
    do: error(path, :config_invalid, "configuration record must be a keyword list")

  defp exact_keys(value, expected, path) do
    if Keyword.keys(value) |> Enum.sort() == Enum.sort(expected),
      do: :ok,
      else: error(path, :config_invalid, "configuration record has missing or extra fields")
  end

  defp fetch(keyword, key), do: Keyword.get(keyword, key, :__rekindle_missing__)

  defp exact(value, value, _path), do: :ok

  defp exact(_value, _expected, path),
    do: error(path, :config_invalid, "configuration value is invalid")

  defp nonempty(value, _path) when is_list(value) and value != [], do: :ok
  defp nonempty(_value, path), do: error(path, :config_invalid, "value must be nonempty")

  defp boolean(value, _path) when is_boolean(value), do: {:ok, value}
  defp boolean(_value, path), do: error(path, :config_invalid, "value must be boolean")

  defp positive(value, _path) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive(_value, path),
    do: error(path, :config_invalid, "value must be a positive integer")

  defp optional_positive(nil, _path), do: {:ok, nil}
  defp optional_positive(value, path), do: positive(value, path)

  defp nonnegative(value, _path) when is_integer(value) and value >= 0, do: {:ok, value}

  defp nonnegative(_value, path),
    do: error(path, :config_invalid, "value must be a nonnegative integer")

  defp member(value, allowed, path) do
    if value in allowed do
      {:ok, value}
    else
      error(path, :config_invalid, "value is outside the closed set")
    end
  end

  defp identifier(value, path) do
    if is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
         not Regex.match?(~r/[\x00-\x1F\x7F]/, value) and ascii?(value) do
      {:ok, value}
    else
      error(path, :config_invalid, "identifier must be bounded printable ASCII")
    end
  end

  defp optional_identifier(nil, _path), do: {:ok, nil}
  defp optional_identifier(value, path), do: identifier(value, path)

  defp identifiers(value, path) when is_list(value) do
    with true <- length(value) <= 128,
         true <- Enum.all?(value, &match?({:ok, _}, identifier(&1, path))) do
      unique_sorted(value, & &1, path)
    else
      _ -> error(path, :config_invalid, "identifier list is invalid")
    end
  end

  defp identifiers(_value, path), do: error(path, :config_invalid, "identifier list is invalid")

  defp env_names(value, path) when is_list(value) do
    with true <- Enum.all?(value, &match?({:ok, _}, env_name(&1, path))) do
      unique_sorted(value, & &1, path)
    else
      _ -> error(path, :config_invalid, "environment name list is invalid")
    end
  end

  defp env_names(_value, path),
    do: error(path, :config_invalid, "environment name list is invalid")

  defp env_name(value, path) do
    if is_binary(value) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/, value) and
         not String.starts_with?(value, "REKINDLE_") do
      {:ok, value}
    else
      error(path, :config_invalid, "environment name is invalid or reserved")
    end
  end

  defp normalized_paths(value, path) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case relative_path(item, path) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, values} -> unique_sorted(Enum.reverse(values), & &1, path)
      error -> error
    end)
  end

  defp normalized_paths(_value, path), do: error(path, :path_invalid, "path list is invalid")

  defp optional_path(nil, _path), do: {:ok, nil}
  defp optional_path(value, path), do: relative_path(value, path)

  defp relative_path(value, path) when is_binary(value) do
    segments = String.split(value, "/")

    if value != "" and byte_size(value) <= 4096 and String.valid?(value) and
         String.normalize(value, :nfc) == value and Path.type(value) != :absolute and
         not String.contains?(value, ["\\", <<0>>]) and
         Enum.all?(segments, &(&1 not in ["", ".", ".."])) and
         not Regex.match?(~r/[\x00-\x1F\x7F]/, value) do
      {:ok, Enum.join(segments, "/")}
    else
      error(path, :path_invalid, "path must be normalized and project-relative")
    end
  end

  defp relative_path(_value, path),
    do: error(path, :path_invalid, "path must be normalized and project-relative")

  defp absolute_path(value, path) when is_binary(value) do
    if Path.type(value) == :absolute and String.valid?(value) and
         not String.contains?(value, <<0>>) do
      {:ok, Path.expand(value)}
    else
      error(path, :path_invalid, "tool executable path must be absolute")
    end
  end

  defp absolute_path(_value, path),
    do: error(path, :path_invalid, "tool executable path must be absolute")

  defp safe_string(value, path) when is_binary(value) and byte_size(value) <= 1_048_576 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: error(path, :config_invalid, "string value is invalid")
  end

  defp safe_string(_value, path), do: error(path, :config_invalid, "string value is invalid")

  defp unique_sorted(value, key_fun, path) when is_list(value) do
    keys = Enum.map(value, key_fun)

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      {:ok, Enum.sort_by(value, key_fun)}
    else
      error(path, :config_invalid, "values must be unique")
    end
  end

  defp unique_sorted(_value, _key_fun, path),
    do: error(path, :config_invalid, "value must be a list")

  defp ascii?(value), do: Enum.all?(:binary.bin_to_list(value), &(&1 <= 0x7F))

  defp error(path, code, message), do: {:error, ConfigError.new(path, code, message)}
  defp errors(path, code, message), do: {:error, [ConfigError.new(path, code, message)]}
end
