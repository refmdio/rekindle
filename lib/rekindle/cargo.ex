defmodule Rekindle.Cargo do
  @moduledoc false
  use GenServer

  alias Rekindle.Cargo.{Arguments, BuildStream, Discovery, Metadata}
  alias Rekindle.BuildGraph.Identity
  alias Rekindle.Scheduler.ResourcePool
  alias Rekindle.Toolchain.{Executable, Rustup}
  alias Rekindle.{Failure, ProcessRunner, Scheduler}

  defmodule MetadataResult do
    @moduledoc false
    @enforce_keys [:request, :metadata, :inventory, :execution]
    defstruct @enforce_keys
  end

  defmodule BuildResult do
    @moduledoc false
    @enforce_keys [:build_key, :request, :artifact, :diagnostics, :execution]
    defstruct @enforce_keys
  end

  defmodule Artifact do
    @moduledoc false
    @enforce_keys [:path, :sha256, :size, :mode]
    defstruct @enforce_keys
  end

  defstruct [
    :runner,
    :helper,
    :pool,
    :authority_owner,
    :authority_monitor,
    owner_alive?: true,
    jobs: %{},
    runner_jobs: %{},
    completed: %{},
    latest_revisions: %{},
    identities: %{},
    authorities: %{},
    supersessions: []
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @spec metadata(GenServer.server(), keyword()) ::
          {:ok, reference()} | {:busy, atom()} | {:error, Failure.t()}
  def metadata(server, options), do: GenServer.call(server, {:start, :metadata, options})

  @spec build(GenServer.server(), keyword()) ::
          {:ok, reference()} | {:busy, atom()} | {:error, Failure.t()}
  def build(server, options), do: GenServer.call(server, {:start, :build, options})

  @spec cancel(GenServer.server(), reference(), :obsolete | :shutdown | :caller) ::
          :ok | {:error, Failure.t()}
  def cancel(server, reference, reason),
    do: GenServer.call(server, {:cancel, reference, reason})

  @spec authorize(GenServer.server(), %Identity.NodeKey{}, Scheduler.t()) ::
          {:ok, reference()} | {:error, Failure.t()}
  def authorize(server, %Identity.NodeKey{} = identity, %Scheduler{} = scheduler),
    do: GenServer.call(server, {:authorize, identity, scheduler})

  @spec supersede(GenServer.server(), reference(), Scheduler.t()) ::
          :ok | {:error, Failure.t()}
  def supersede(server, authority, %Scheduler{} = scheduler),
    do: GenServer.call(server, {:supersede, authority, scheduler})

  @spec result(GenServer.server(), reference(), reference()) ::
          {:ok, %MetadataResult{} | %BuildResult{}} | {:error, Failure.t()}
  def result(server, reference, authority),
    do: GenServer.call(server, {:result, reference, authority})

  @impl true
  def init(options) do
    runner = Keyword.fetch!(options, :runner)
    helper = Keyword.fetch!(options, :helper)
    authority_owner = Keyword.fetch!(options, :authority_owner)
    max_cargo = Keyword.get(options, :max_cargo_builds, 2)
    {:ok, pool} = ResourcePool.new(max_cargo, 1)
    authority_monitor = Process.monitor(authority_owner)

    {:ok,
     %__MODULE__{
       runner: runner,
       helper: helper,
       pool: pool,
       authority_owner: authority_owner,
       authority_monitor: authority_monitor
     }}
  end

  @impl true
  def handle_call({:start, operation, options}, {caller, _tag}, state) do
    with {:ok, job} <- admit(operation, caller, options, state),
         {:ok, pool} <- ResourcePool.acquire_cargo(state.pool, job.reference, job.cache_key),
         {:ok, pool} <- ResourcePool.acquire_helper(pool, job.reference),
         {:ok, runner_reference} <- ProcessRunner.run(state.runner, runner_request(job)) do
      job = %{job | runner_reference: runner_reference}

      {:reply, {:ok, job.reference},
       %{
         state
         | pool: pool,
           jobs: Map.put(state.jobs, job.reference, job),
           runner_jobs: Map.put(state.runner_jobs, runner_reference, job.reference)
       }}
    else
      {:busy, reason, _pool} -> {:reply, {:busy, reason}, state}
      {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:authorize, identity, scheduler}, {caller, _tag}, state) do
    with true <- caller == state.authority_owner,
         {:ok, build_key, source_revision} <-
           execution_authority(
             identity,
             scheduler,
             scheduler.target,
             identity.input["profile"]
           ),
         {:ok, authority_token, state} <-
           register_authority(state, identity, scheduler.target, source_revision, build_key) do
      {:reply, {:ok, authority_token}, state}
    else
      {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
      _ -> {:reply, failure(:cargo_protocol, nil, "Cargo authority issuer is invalid"), state}
    end
  end

  def handle_call({:supersede, authority_token, scheduler}, {caller, _tag}, state) do
    authority = Map.get(state.authorities, authority_token)

    case supersession(caller, authority_token, authority, scheduler, state) do
      {:ok, target, running_revision, latest_revision} ->
        state =
          advance_authority(
            state,
            authority_token,
            target,
            running_revision,
            latest_revision
          )

        case cancel_obsolete(state, target, running_revision) do
          :ok -> {:reply, :ok, state}
          {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
        end

      {:already, _revision} ->
        {:reply, :ok, state}

      {:error, %Failure{} = failure} ->
        {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:result, reference, authority_token}, {caller, _tag}, state) do
    with true <- caller == state.authority_owner,
         {{job, process_result}, completed} <- Map.pop(state.completed, reference),
         true <- job.authority == authority_token do
      mapped = authoritative_result(job, process_result, state)
      {:ok, pool} = ResourcePool.release_cargo(state.pool, reference)
      {:reply, mapped, %{state | pool: pool, completed: completed}}
    else
      {nil, _completed} ->
        {:reply, failure(:cargo_protocol, nil, "Cargo result is not ready"), state}

      _ ->
        {:reply, failure(:cargo_protocol, nil, "Cargo result authority is invalid"), state}
    end
  end

  def handle_call({:cancel, reference, reason}, {caller, _tag}, state) do
    case Map.fetch(state.jobs, reference) do
      {:ok, %{caller: ^caller} = job} ->
        {:reply, ProcessRunner.cancel(state.runner, job.runner_reference, reason), state}

      _ ->
        {:reply, failure(:cancelled, nil, "Cargo job is not owned by the caller"), state}
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, failure(:cargo_protocol, nil, "Cargo request envelope is invalid"), state}

  @impl true
  def handle_info({:rekindle_process, runner_reference, result}, state) do
    case Map.pop(state.runner_jobs, runner_reference) do
      {nil, _runner_jobs} ->
        {:noreply, state}

      {reference, runner_jobs} ->
        {job, jobs} = Map.pop(state.jobs, reference)
        {:ok, pool} = ResourcePool.release_helper(state.pool, reference)

        if state.owner_alive? do
          send(state.authority_owner, {:rekindle_cargo_ready, reference})

          {:noreply,
           %{
             state
             | pool: pool,
               jobs: jobs,
               runner_jobs: runner_jobs,
               completed: Map.put(state.completed, reference, {job, result})
           }}
        else
          {:ok, pool} = ResourcePool.release_cargo(pool, reference)

          {:noreply, %{state | pool: pool, jobs: jobs, runner_jobs: runner_jobs}}
        end
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{authority_monitor: monitor, authority_owner: owner} = state
      ) do
    Enum.each(state.jobs, fn {_reference, job} ->
      _ = ProcessRunner.cancel(state.runner, job.runner_reference, :caller)
    end)

    pool =
      Enum.reduce(state.completed, state.pool, fn {reference, _result}, pool ->
        {:ok, pool} = ResourcePool.release_cargo(pool, reference)
        pool
      end)

    {:noreply,
     %{
       state
       | pool: pool,
         owner_alive?: false,
         completed: %{},
         latest_revisions: %{},
         identities: %{},
         authorities: %{},
         supersessions: []
     }}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp admit(operation, caller, options, state)
       when operation in [:metadata, :build] and is_list(options) do
    target = Keyword.get(options, :target)
    config = Keyword.get(options, :config)
    client_root = Keyword.get(options, :client_root)
    mode = Keyword.get(options, :mode, :dev)
    rust_target = Keyword.get(options, :rust_target)
    authority_token = Keyword.get(options, :authority)
    target_directory = Keyword.get(options, :target_directory)

    with true <- target in [:web, :desktop],
         true <- normalized_absolute?(target_directory),
         {:ok, request} <-
           apply(Arguments, operation, [client_root, target, config, mode, rust_target]),
         {:ok, authority} <-
           active_authority(state, authority_token, target, request.selection.profile),
         {:ok, executable, argv, tool_environment} <-
           command(config, request.argv, target),
         :ok <- Executable.revalidate(executable),
         {:ok, environment} <-
           environment(config.environment, target_directory, tool_environment),
         :ok <- operation_inputs(operation, options, target_directory) do
      {:ok,
       %{
         reference: make_ref(),
         runner_reference: nil,
         caller: caller,
         operation: operation,
         target: target,
         request: request,
         config: config,
         authority: authority_token,
         source_revision: authority.source_revision,
         build_key: authority.build_key,
         cache_key: cache_key(target_directory),
         target_directory: target_directory,
         project_root: Keyword.get(options, :project_root),
         inventory: Keyword.get(options, :inventory),
         helper: state.helper,
         executable: executable.path,
         argv: argv,
         environment: environment,
         redact_values: redaction_values(config.environment, environment),
         process: Keyword.get(options, :process)
       }}
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      _ -> failure(:cargo_protocol, target, "Canonical Cargo request is invalid")
    end
  end

  defp admit(_operation, _caller, _options, _state),
    do: failure(:cargo_protocol, nil, "Canonical Cargo request is invalid")

  defp execution_authority(
         %Identity.NodeKey{} = identity,
         %Scheduler{} = scheduler,
         target,
         profile
       )
       when target in [:web, :desktop] and is_binary(profile) do
    node = cargo_node(target)

    with {:ok, digest} <- Identity.digest("rekindle-node-v1\0", identity.input),
         true <- identity.key == digest.digest,
         true <- identity.preimage == digest.preimage,
         true <- identity.model_slice_digest == identity.input["model_slice_digest"],
         true <- identity.config_digest == identity.input["config_digest"],
         true <- identity.input["node"] == Atom.to_string(node),
         true <- identity.input["target"] == Atom.to_string(target),
         true <- identity.input["profile"] == profile,
         true <- scheduler.target == target,
         true <- scheduler.state == :building,
         revision when is_integer(revision) and revision >= 0 <- scheduler.running_revision,
         true <- scheduler.latest_source_revision == revision,
         true <- scheduler.queued_revision == nil,
         true <- scheduler.cancel_requested? == false,
         true <- node in scheduler.affected_nodes do
      {:ok, identity.key, revision}
    else
      _ -> failure(:cargo_protocol, target, "Cargo execution authority is invalid")
    end
  end

  defp execution_authority(_identity, _scheduler, target, _profile),
    do: failure(:cargo_protocol, target, "Cargo execution authority is invalid")

  defp active_authority(state, token, target, profile) do
    case Map.get(state.authorities, token) do
      %{
        status: :active,
        target: ^target,
        source_revision: revision,
        identity: %Identity.NodeKey{} = identity
      } = authority
      when revision >= 0 ->
        if Map.get(state.latest_revisions, target) == revision and
             identity.input["profile"] == profile do
          {:ok, authority}
        else
          failure(:cancelled, target, "Cargo execution authority is obsolete")
        end

      _ ->
        failure(:cargo_protocol, target, "Cargo execution authority is invalid")
    end
  end

  defp register_authority(state, identity, target, source_revision, build_key) do
    latest = Map.get(state.latest_revisions, target, -1)
    key = {target, source_revision}

    cond do
      source_revision < latest ->
        failure(:cancelled, target, "Cargo source revision is obsolete")

      Map.has_key?(state.identities, key) and state.identities[key] != identity ->
        failure(
          :cargo_protocol,
          target,
          "Cargo build identity changed within a source revision"
        )

      true ->
        case current_authority(state, target, source_revision, identity) do
          {token, _authority} ->
            {:ok, token, state}

          nil ->
            token = make_ref()

            authority = %{
              token: token,
              identity: identity,
              target: target,
              source_revision: source_revision,
              build_key: build_key,
              status: :active
            }

            {:ok, token,
             %{
               state
               | latest_revisions: Map.put(state.latest_revisions, target, source_revision),
                 identities:
                   state.identities
                   |> reject_target(target)
                   |> Map.put(key, identity),
                 authorities:
                   state.authorities
                   |> reject_target(target)
                   |> Map.put(token, authority)
             }}
        end
    end
  end

  defp current_authority(state, target, source_revision, identity) do
    Enum.find(state.authorities, fn {_token, authority} ->
      authority.target == target and authority.source_revision == source_revision and
        authority.identity == identity and authority.status == :active
    end)
  end

  defp supersession(caller, authority_token, authority, %Scheduler{} = scheduler, state) do
    current = Map.get(state.latest_revisions, scheduler.target, -1)

    key =
      {authority_token, scheduler.target, scheduler.running_revision,
       scheduler.latest_source_revision}

    cond do
      caller != state.authority_owner ->
        failure(:cargo_protocol, scheduler.target, "Cargo supersession owner is invalid")

      scheduler.state not in [:building, :validating] ->
        failure(:cargo_protocol, scheduler.target, "Cargo supersession state is invalid")

      not scheduler.cancel_requested? ->
        failure(:cargo_protocol, scheduler.target, "Cargo supersession was not requested")

      not is_integer(scheduler.running_revision) or scheduler.running_revision < 0 ->
        failure(:cargo_protocol, scheduler.target, "Cargo running revision is invalid")

      scheduler.latest_source_revision <= scheduler.running_revision ->
        failure(:cargo_protocol, scheduler.target, "Cargo supersession revision is invalid")

      scheduler.queued_revision != scheduler.latest_source_revision ->
        failure(:cargo_protocol, scheduler.target, "Cargo queued revision is invalid")

      key in state.supersessions ->
        {:already, scheduler.latest_source_revision}

      not is_map(authority) or authority.target != scheduler.target ->
        failure(:cargo_protocol, scheduler.target, "Cargo supersession authority is invalid")

      authority.source_revision != scheduler.running_revision ->
        failure(:cargo_protocol, scheduler.target, "Cargo supersession authority is invalid")

      scheduler.running_revision != current ->
        failure(:cargo_protocol, scheduler.target, "Cargo running revision is not owned")

      true ->
        {:ok, scheduler.target, scheduler.running_revision, scheduler.latest_source_revision}
    end
  end

  defp advance_authority(state, authority_token, target, running_revision, latest_revision) do
    identities =
      state.identities
      |> Enum.reject(fn {{identity_target, revision}, _identity} ->
        identity_target == target and revision < latest_revision
      end)
      |> Map.new()

    authorities =
      Map.reject(state.authorities, fn {_token, authority} ->
        authority.target == target and authority.source_revision <= running_revision
      end)

    %{
      state
      | latest_revisions: Map.put(state.latest_revisions, target, latest_revision),
        identities: identities,
        authorities: authorities,
        supersessions:
          [
            {authority_token, target, running_revision, latest_revision}
            | state.supersessions
          ]
          |> Enum.take(16)
    }
  end

  defp reject_target(entries, target) do
    Map.reject(entries, fn
      {{entry_target, _revision}, _value} -> entry_target == target
      {_token, %{target: entry_target}} -> entry_target == target
    end)
  end

  defp cancel_obsolete(state, target, running_revision) do
    state.jobs
    |> Map.values()
    |> Enum.filter(&(&1.target == target and &1.source_revision <= running_revision))
    |> Enum.reduce_while(:ok, fn job, :ok ->
      case ProcessRunner.cancel(state.runner, job.runner_reference, :obsolete) do
        :ok -> {:cont, :ok}
        {:error, %Failure{} = failure} -> {:halt, {:error, failure}}
      end
    end)
  end

  defp authoritative_result(job, result, state) do
    authority = Map.get(state.authorities, job.authority)

    if job.source_revision < Map.get(state.latest_revisions, job.target, 0) or
         not match?(%{status: :active}, authority) do
      obsolete_result(job, result)
    else
      map_result(job, result)
    end
  end

  defp obsolete_result(job, {:ok, %{execution: %{cleanup: :uncertain}}}),
    do: failure(:cleanup_unconfirmed, job.target, "Cargo cleanup was not confirmed")

  defp obsolete_result(_job, {:error, %Failure{code: :cleanup_unconfirmed} = failure}),
    do: {:error, failure}

  defp obsolete_result(job, _result),
    do: failure(:cancelled, job.target, "Cargo source revision was superseded")

  defp cache_key(target_directory),
    do: sha256("rekindle-cargo-cache-v1\0" <> target_directory)

  defp cargo_node(:web), do: :cargo_web
  defp cargo_node(:desktop), do: :cargo_desktop

  defp command(%{toolchain: %{kind: :rustup, name: name}}, argv, _target) do
    with {:ok, rustup} <- Rustup.resolve() do
      {:ok, rustup, ["run", name, "cargo" | argv], {:rustup, Path.dirname(rustup.path)}}
    end
  end

  defp command(%{toolchain: %{kind: :path, cargo: cargo, rustc: rustc}}, argv, target) do
    with {:ok, cargo} <- qualify(cargo, target, "cargo"),
         {:ok, rustc} <- qualify(rustc, target, "rustc") do
      {:ok, cargo, argv, {:path, rustc.path}}
    end
  end

  defp command(_config, _argv, target),
    do: failure(:tool_missing, target, "Qualified Cargo toolchain is unavailable")

  defp qualify(path, target, name) do
    case Executable.qualify(path) do
      {:ok, executable} -> {:ok, executable}
      _ -> failure(:tool_missing, target, "Qualified #{name} executable is unavailable")
    end
  end

  defp environment(policy, target_directory, tool_environment) do
    with {:ok, resolved} <- tool_environment(policy.resolved, tool_environment) do
      entries =
        [{"CARGO_TARGET_DIR", target_directory} | resolved] |> Enum.sort_by(&elem(&1, 0))

      if length(entries) == length(Enum.uniq_by(entries, &elem(&1, 0))),
        do: {:ok, entries},
        else: failure(:contract_violation, nil, "Cargo environment contains duplicate names")
    end
  end

  defp tool_environment(resolved, {:rustup, proxy_directory}) do
    path =
      resolved
      |> Enum.find_value(fn
        {"PATH", value} -> value
        _entry -> nil
      end)

    effective_path =
      [proxy_directory | split_path(path)]
      |> Enum.uniq()
      |> Enum.join(path_separator())

    {:ok,
     resolved
     |> Enum.reject(&(elem(&1, 0) == "PATH"))
     |> List.insert_at(0, {"PATH", effective_path})}
  end

  defp tool_environment(resolved, {:path, rustc}) do
    if Enum.any?(resolved, &(elem(&1, 0) == "RUSTC")),
      do: failure(:contract_violation, nil, "Cargo environment overrides the selected rustc"),
      else: {:ok, [{"RUSTC", rustc} | resolved]}
  end

  defp split_path(nil), do: []
  defp split_path(path), do: String.split(path, path_separator(), trim: true)

  defp path_separator, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")

  defp operation_inputs(:metadata, options, _target_directory) do
    if normalized_absolute?(Keyword.get(options, :project_root)), do: :ok, else: :error
  end

  defp operation_inputs(:build, options, target_directory) do
    case Keyword.get(options, :inventory) do
      %Discovery.Inventory{target_directory: ^target_directory} ->
        if normalized_absolute?(Keyword.get(options, :project_root)), do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp runner_request(job) do
    process = job.process

    [
      target: job.target,
      build_key: job.build_key,
      helper: job.helper,
      executable: job.executable,
      argv: job.argv,
      cwd: job.request.cwd,
      env_mode: :replace,
      env_set: job.environment,
      env_unset: [],
      redact_values: job.redact_values,
      terminate_grace_ms: process.terminate_grace_ms,
      kill_grace_ms: process.kill_grace_ms,
      output_bytes_per_stream: process.output_bytes_per_stream,
      build_timeout_ms: process.build_timeout_ms,
      cleanup_timeout_ms: process.kill_grace_ms
    ]
  end

  defp redaction_values(policy, environment) do
    names = MapSet.new(policy.redact)

    environment
    |> Enum.flat_map(fn {name, value} ->
      if MapSet.member?(names, name), do: [value], else: []
    end)
    |> Enum.uniq()
  end

  defp map_result(_job, {:error, %Failure{} = failure}), do: {:error, failure}

  defp map_result(%{operation: :metadata} = job, {:ok, result}) do
    with :ok <- successful_execution(result.execution, job.target),
         {:ok, metadata} <- Metadata.decode(result.stdout, job.target),
         {:ok, inventory} <- Discovery.select(metadata, job.request.selection) do
      {:ok,
       %MetadataResult{
         request: job.request,
         metadata: metadata,
         inventory: inventory,
         execution: result.execution
       }}
    end
  end

  defp map_result(%{operation: :build} = job, {:ok, result}) do
    selected = job.inventory.selected_target

    with {:ok, stream} <-
           BuildStream.new(
             target: job.target,
             package_id: job.inventory.selected_package.id,
             target_name: selected.name,
             target_kind: Enum.sort(selected.kind),
             target_directory: job.target_directory,
             project_root: job.project_root
           ),
         {:ok, stream} <- BuildStream.push(stream, result.stdout),
         {:ok, stream} <- BuildStream.push_stderr(stream, result.stderr),
         {:ok, selected} <- BuildStream.finish(stream, result.execution),
         {:ok, artifact} <- admit_artifact(selected.artifact, job.target) do
      {:ok,
       %BuildResult{
         build_key: job.build_key,
         request: job.request,
         artifact: artifact,
         diagnostics: selected.diagnostics,
         execution: result.execution
       }}
    end
  end

  defp successful_execution(%{outcome: :exited, exit_code: 0, cleanup: :confirmed}, _target),
    do: :ok

  defp successful_execution(%{cleanup: :uncertain}, target),
    do: failure(:cleanup_unconfirmed, target, "Cargo cleanup was not confirmed")

  defp successful_execution(_execution, target),
    do: failure(:cargo_metadata_failed, target, "Cargo metadata command failed")

  defp admit_artifact(path, target) do
    with {:ok, %File.Stat{type: :regular} = before} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, %File.Stat{type: :regular} = after_read} <- File.lstat(path),
         true <- stable?(before, after_read, bytes) do
      {:ok,
       %Artifact{
         path: path,
         sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         size: byte_size(bytes),
         mode: Bitwise.band(after_read.mode, 0o777)
       }}
    else
      false -> failure(:artifact_changed, target, "Cargo artifact changed during admission")
      _ -> failure(:artifact_missing, target, "Cargo artifact is not a regular file")
    end
  end

  defp stable?(left, right, bytes),
    do:
      left.inode == right.inode and left.major_device == right.major_device and
        left.minor_device == right.minor_device and left.size == right.size and
        left.mtime == right.mtime and right.size == byte_size(bytes)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp normalized_absolute?(value),
    do: is_binary(value) and Path.type(value) == :absolute and Path.expand(value) == value

  defp failure(code, target, message) do
    {:error,
     Failure.new!(
       target: if(target in [:web, :desktop], do: target, else: nil),
       stage: elem(Failure.stage_for(code), 1),
       code: code,
       message: message
     )}
  end
end
