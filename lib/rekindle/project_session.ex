defmodule Rekindle.ProjectSession do
  @moduledoc false

  use GenServer

  alias Rekindle.{BuildResult, Failure}
  alias Rekindle.Scheduler.Session

  defstruct [
    :project,
    :session,
    :session_id,
    :worker_supervisor,
    pending: %{},
    jobs: %{},
    monitors: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    project = Keyword.fetch!(options, :project)
    key = {:session, project.project_root}

    GenServer.start_link(__MODULE__, project,
      name: {:via, Registry, {Rekindle.RuntimeRegistry, key}}
    )
  end

  @spec build(
          Rekindle.otp_app(),
          String.t(),
          Rekindle.target(),
          (Rekindle.Config.Project.t(), non_neg_integer() ->
             {:ok, BuildResult.t()} | {:error, Failure.t()})
        ) ::
          {:ok, BuildResult.t()} | {:error, Failure.t()}
  def build(otp_app, project_root, target, executor) when is_function(executor, 2) do
    case lookup(project_root) do
      [{pid, _value}] -> GenServer.call(pid, {:build, otp_app, target, executor}, :infinity)
      [] -> unavailable(target)
    end
  end

  @spec identity(Rekindle.otp_app(), String.t()) :: {:ok, String.t()} | :none
  def identity(otp_app, project_root) do
    case lookup(project_root) do
      [{pid, _value}] -> GenServer.call(pid, {:identity, otp_app})
      [] -> :none
    end
  end

  @impl true
  def init(project) do
    nodes = target_nodes(project)

    with {:ok, worker_supervisor} <- Task.Supervisor.start_link(),
         {:ok, session, _admission_revision, _effects} <-
           Session.new(nodes, %{}, project.dev.debounce_ms) do
      {:ok,
       %__MODULE__{
         project: project,
         session: session,
         session_id: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
         worker_supervisor: worker_supervisor
       }}
    else
      {:error, %Failure{} = failure} ->
        {:stop, failure}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.worker_supervisor) and Process.alive?(state.worker_supervisor) do
      Supervisor.stop(state.worker_supervisor, :shutdown)
    end

    :ok
  end

  @impl true
  def handle_call({:identity, otp_app}, _from, %{project: %{otp_app: otp_app}} = state),
    do: {:reply, {:ok, state.session_id}, state}

  def handle_call({:identity, _otp_app}, _from, state), do: {:reply, :none, state}

  def handle_call({:build, otp_app, target, executor}, from, state) do
    caller = make_ref()
    nodes = target_nodes(state.project)

    with true <- otp_app == state.project.otp_app,
         true <- is_function(executor, 2),
         {:ok, target_node} <- Map.fetch(nodes, target),
         {:ok, session, _revision, effects} <-
           Session.request(
             state.session,
             target,
             target_node,
             caller
           ) do
      monitor = Process.monitor(elem(from, 0))

      state = %{
        state
        | session: session,
          pending:
            Map.put(state.pending, caller, %{from: from, executor: executor, monitor: monitor}),
          monitors: Map.put(state.monitors, monitor, {:caller, caller})
      }

      {:noreply, apply_effects(state, effects)}
    else
      false -> {:reply, invalid(target, "Build executor is invalid"), state}
      :error -> {:reply, invalid(target, "Build target is not admitted"), state}
      {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
    end
  end

  @impl true
  def handle_info({:project_build_result, revision, result}, state) do
    case Map.pop(state.jobs, revision) do
      {nil, _jobs} ->
        {:noreply, state}

      {job, jobs} ->
        Process.demonitor(job.monitor, [:flush])
        state = %{state | jobs: jobs, monitors: Map.delete(state.monitors, job.monitor)}
        {:noreply, finish_build(state, job.target, revision, result)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:caller, caller}, monitors} ->
        state = %{state | monitors: monitors}

        case Map.pop(state.pending, caller) do
          {nil, _pending} ->
            {:noreply, state}

          {%{monitor: ^monitor}, pending} ->
            session =
              case Session.detach_caller(state.session, caller) do
                {:ok, session} -> session
                {:error, %Failure{}} -> state.session
              end

            {:noreply, %{state | pending: pending, session: session}}
        end

      {{:worker, revision}, monitors} ->
        case Map.pop(state.jobs, revision) do
          {nil, _jobs} ->
            {:noreply, %{state | monitors: monitors}}

          {job, jobs} ->
            failure =
              if reason == :killed,
                do: cancelled(job.target),
                else: elem(invalid(job.target, "Target handler terminated"), 1)

            state = %{state | jobs: jobs, monitors: monitors}
            {:noreply, finish_build(state, job.target, revision, {:error, failure})}
        end
    end
  end

  defp finish_build(state, target, revision, {:ok, %BuildResult{} = result}) do
    with {:ok, session} <- Session.advance(state.session, target, revision, :validating),
         {:ok, session} <- Session.advance(session, target, revision, :publishing),
         {:ok, session, effects} <-
           Session.succeed(session, target, revision, result.generation, result) do
      apply_effects(%{state | session: session}, effects)
    else
      {:obsolete, session} ->
        {:ok, session, effects} =
          Session.succeed(session, target, revision, result.generation, result)

        apply_effects(%{state | session: session}, effects)

      {:error, %Failure{} = failure} ->
        finish_build(state, target, revision, {:error, failure})
    end
  end

  defp finish_build(state, target, revision, {:error, %Failure{} = failure}) do
    case Session.fail(state.session, target, revision, failure) do
      {:ok, session, effects} -> apply_effects(%{state | session: session}, effects)
      {:error, %Failure{} = contract} -> fail_pending(state, revision, contract)
    end
  end

  defp finish_build(state, target, revision, _result),
    do: finish_build(state, target, revision, invalid(target, "Target handler result is invalid"))

  defp apply_effects(state, effects) do
    Enum.reduce(effects, state, &apply_effect(&1, &2))
  end

  defp apply_effect({:request_token, target, token, revision}, state) do
    case Session.grant(state.session, target, token, revision) do
      {:ok, session, effects} -> apply_effects(%{state | session: session}, effects)
      {:error, %Failure{} = failure} -> fail_pending(state, revision, failure)
    end
  end

  defp apply_effect({:start, target, revision, _nodes}, state) do
    caller = Map.get(state.session.callers, revision)

    case Map.get(state.pending, caller) do
      %{executor: executor} ->
        owner = self()

        {:ok, pid} =
          Task.Supervisor.start_child(state.worker_supervisor, fn ->
            send(owner, {:project_build_result, revision, executor.(state.project, revision)})
          end)

        monitor = Process.monitor(pid)

        job = %{pid: pid, monitor: monitor, target: target}

        %{
          state
          | jobs: Map.put(state.jobs, revision, job),
            monitors: Map.put(state.monitors, monitor, {:worker, revision})
        }

      nil ->
        state
    end
  end

  defp apply_effect({:cancel, _target, revision, _reason}, state) do
    case Map.get(state.jobs, revision) do
      %{pid: pid} -> Process.exit(pid, :kill)
      nil -> :ok
    end

    state
  end

  defp apply_effect({:caller, caller, result}, state) do
    case Map.pop(state.pending, caller) do
      {nil, _pending} ->
        state

      {%{from: from, monitor: monitor}, pending} ->
        Process.demonitor(monitor, [:flush])
        GenServer.reply(from, result)

        %{
          state
          | pending: pending,
            monitors: Map.delete(state.monitors, monitor)
        }
    end
  end

  defp apply_effect(_effect, state), do: state

  defp fail_pending(state, revision, failure) do
    case Map.get(state.session.callers, revision) do
      nil -> state
      caller -> apply_effect({:caller, caller, {:error, failure}}, state)
    end
  end

  defp target_nodes(project) do
    Map.new(project.build.targets, fn
      {:web, %{backend: :canonical}} ->
        {:web, [:cargo_web, :bindgen_web, :package_web, :seal_web]}

      {:web, %{backend: {:external, _}}} ->
        {:web, [:external_web, :seal_web]}

      {:desktop, %{backend: :canonical}} ->
        {:desktop, [:cargo_desktop, :seal_desktop]}

      {:desktop, %{backend: {:external, _}}} ->
        {:desktop, [:external_desktop, :seal_desktop]}
    end)
  end

  defp lookup(project_root) do
    key = {:session, Path.expand(project_root)}
    Registry.lookup(Rekindle.RuntimeRegistry, key)
  end

  defp unavailable(target),
    do: invalid(target, "Project build session is not running")

  defp cancelled(target) do
    Failure.new!(
      target: target,
      stage: :execution,
      code: :cancelled,
      message: "Build was superseded"
    )
  end

  defp invalid(target, message) do
    {:error,
     Failure.new!(target: target, stage: :internal, code: :unexpected_state, message: message)}
  end
end
