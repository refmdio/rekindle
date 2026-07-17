defmodule Rekindle.Cargo do
  @moduledoc false
  use GenServer

  alias Rekindle.Cargo.{Arguments, BuildStream, Discovery, Metadata}
  alias Rekindle.Scheduler.ResourcePool
  alias Rekindle.Toolchain.{Executable, Rustup}
  alias Rekindle.{Failure, ProcessRunner}

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

  defstruct [:runner, :helper, :pool, jobs: %{}, runner_jobs: %{}]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @spec metadata(GenServer.server(), keyword()) ::
          {:ok, reference()} | {:busy, atom()} | {:error, Failure.t()}
  def metadata(server, options), do: GenServer.call(server, {:start, self(), :metadata, options})

  @spec build(GenServer.server(), keyword()) ::
          {:ok, reference()} | {:busy, atom()} | {:error, Failure.t()}
  def build(server, options), do: GenServer.call(server, {:start, self(), :build, options})

  @spec cancel(GenServer.server(), reference(), :obsolete | :shutdown | :caller) ::
          :ok | {:error, Failure.t()}
  def cancel(server, reference, reason),
    do: GenServer.call(server, {:cancel, self(), reference, reason})

  @impl true
  def init(options) do
    runner = Keyword.fetch!(options, :runner)
    helper = Keyword.fetch!(options, :helper)
    max_cargo = Keyword.get(options, :max_cargo_builds, 2)
    {:ok, pool} = ResourcePool.new(max_cargo, 1)
    {:ok, %__MODULE__{runner: runner, helper: helper, pool: pool}}
  end

  @impl true
  def handle_call({:start, caller, operation, options}, _from, state) do
    with {:ok, job} <- admit(operation, caller, options, state.helper),
         {:ok, pool} <- ResourcePool.acquire_cargo(state.pool, job.reference, job.cache_key),
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

  def handle_call({:cancel, caller, reference, reason}, _from, state) do
    case Map.fetch(state.jobs, reference) do
      {:ok, %{caller: ^caller} = job} ->
        {:reply, ProcessRunner.cancel(state.runner, job.runner_reference, reason), state}

      _ ->
        {:reply, failure(:cancelled, nil, "Cargo job is not owned by the caller"), state}
    end
  end

  @impl true
  def handle_info({:rekindle_process, runner_reference, result}, state) do
    case Map.pop(state.runner_jobs, runner_reference) do
      {nil, _runner_jobs} ->
        {:noreply, state}

      {reference, runner_jobs} ->
        {job, jobs} = Map.pop(state.jobs, reference)
        mapped = map_result(job, result)
        send(job.caller, {:rekindle_cargo, reference, mapped})
        {:ok, pool} = ResourcePool.release_cargo(state.pool, reference)
        {:noreply, %{state | pool: pool, jobs: jobs, runner_jobs: runner_jobs}}
    end
  end

  defp admit(operation, caller, options, helper)
       when operation in [:metadata, :build] and is_list(options) do
    target = Keyword.get(options, :target)
    config = Keyword.get(options, :config)
    client_root = Keyword.get(options, :client_root)
    mode = Keyword.get(options, :mode, :dev)
    rust_target = Keyword.get(options, :rust_target)
    build_key = Keyword.get(options, :build_key)
    cache_key = Keyword.get(options, :cache_key, build_key)
    target_directory = Keyword.get(options, :target_directory)

    with true <- target in [:web, :desktop],
         true <- sha256?(build_key) and sha256?(cache_key),
         true <- normalized_absolute?(target_directory),
         {:ok, request} <-
           apply(Arguments, operation, [client_root, target, config, mode, rust_target]),
         {:ok, executable, argv} <- command(config, request.argv, target),
         :ok <- Executable.revalidate(executable),
         {:ok, environment} <- environment(config.environment, target_directory),
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
         build_key: build_key,
         cache_key: cache_key,
         target_directory: target_directory,
         project_root: Keyword.get(options, :project_root),
         inventory: Keyword.get(options, :inventory),
         helper: helper,
         executable: executable.path,
         argv: argv,
         environment: environment,
         process: Keyword.get(options, :process)
       }}
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      _ -> failure(:cargo_protocol, target, "Canonical Cargo request is invalid")
    end
  end

  defp admit(_operation, _caller, _options, _helper),
    do: failure(:cargo_protocol, nil, "Canonical Cargo request is invalid")

  defp command(%{toolchain: %{kind: :rustup, name: name}}, argv, _target) do
    with {:ok, rustup} <- Rustup.resolve() do
      {:ok, rustup, ["run", name, "cargo" | argv]}
    end
  end

  defp command(%{toolchain: %{kind: :path, cargo: cargo, rustc: rustc}}, argv, target) do
    with {:ok, cargo} <- qualify(cargo, target, "cargo"),
         {:ok, _rustc} <- qualify(rustc, target, "rustc") do
      {:ok, cargo, argv}
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

  defp environment(policy, target_directory) do
    entries =
      [{"CARGO_TARGET_DIR", target_directory} | policy.resolved] |> Enum.sort_by(&elem(&1, 0))

    if length(entries) == length(Enum.uniq_by(entries, &elem(&1, 0))),
      do: {:ok, entries},
      else: failure(:contract_violation, nil, "Cargo environment contains duplicate names")
  end

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
      terminate_grace_ms: process.terminate_grace_ms,
      kill_grace_ms: process.kill_grace_ms,
      output_bytes_per_stream: process.output_bytes_per_stream,
      build_timeout_ms: process.build_timeout_ms,
      cleanup_timeout_ms: process.kill_grace_ms
    ]
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

  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

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
