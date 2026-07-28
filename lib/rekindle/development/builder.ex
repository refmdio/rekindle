defmodule Rekindle.Development.Builder do
  @moduledoc false

  use GenServer

  require Logger

  alias Rekindle.Build.Result
  alias Rekindle.Config

  @targets [:web, :desktop]

  @type target :: :web | :desktop

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @spec rebuild(GenServer.server(), :all | target() | [target()]) :: :ok
  def rebuild(server, targets \\ :all) do
    GenServer.cast(server, {:rebuild, targets})
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)
    otp_app = Keyword.fetch!(options, :otp_app)

    with {:ok, project} <-
           Config.load(otp_app, project_root: Keyword.get(options, :project_root, File.cwd!())) do
      targets =
        project.targets
        |> Map.take(Keyword.get(options, :targets, Map.keys(project.targets)))
        |> Map.new(fn {target, _config} ->
          {target, target_state()}
        end)

      state = %{
        project: project,
        targets: targets,
        debounce: Keyword.get(options, :debounce, 75),
        notify: Keyword.get(options, :notify),
        build: Keyword.get(options, :build, &build(project, &1, &2)),
        activate: Keyword.get(options, :activate, &activate(project, &1)),
        build_options: Keyword.get(options, :build_options, [])
      }

      {:ok, state}
    else
      {:error, error} -> {:stop, error}
    end
  end

  @impl GenServer
  def handle_cast({:rebuild, requested}, state) do
    {:noreply, schedule(state, requested)}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status =
      Map.new(state.targets, fn {target, target_state} ->
        {target,
         %{
           building?: not is_nil(target_state.running),
           last_success: target_state.last_success,
           pending?: target_state.pending?
         }}
      end)

    {:reply, status, state}
  end

  @impl GenServer
  def handle_info({:build, target, token}, state) do
    target_state = Map.fetch!(state.targets, target)

    state =
      if match?({_timer, ^token}, target_state.timer) do
        target_state = %{target_state | timer: nil}

        if target_state.running do
          put_target(state, target, %{target_state | pending?: true})
        else
          start_build(state, target, target_state)
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({reference, result}, state) when is_reference(reference) do
    case running_target(state.targets, reference) do
      nil ->
        {:noreply, state}

      {target, target_state} ->
        Process.demonitor(reference, [:flush])
        elapsed = elapsed(target_state.running.started_at)
        {target_state, result} = finish_current(state, target, target_state, result)

        state = put_target(state, target, target_state)

        report(state.project, target, result, elapsed)
        notify(state.notify, target, result)

        state =
          if target_state.pending? and is_nil(target_state.timer) do
            target_state = %{target_state | pending?: false}
            start_build(state, target, target_state)
          else
            state
          end

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case running_target(state.targets, reference) do
      nil ->
        {:noreply, state}

      {target, target_state} ->
        result = {:error, {:build_process, reason}}
        elapsed = elapsed(target_state.running.started_at)
        target_state = %{target_state | running: nil}
        state = put_target(state, target, target_state)

        report(state.project, target, result, elapsed)
        notify(state.notify, target, result)

        {:noreply, maybe_start_pending(state, target)}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.targets, fn {_target, target_state} ->
      if target_state.timer, do: Process.cancel_timer(elem(target_state.timer, 0))

      if target_state.running do
        Task.shutdown(target_state.running.task, :brutal_kill)
      end
    end)
  end

  defp schedule(state, requested) do
    requested
    |> normalize_targets(state.targets)
    |> Enum.reduce(state, fn target, state ->
      target_state = Map.fetch!(state.targets, target)

      if target_state.timer, do: Process.cancel_timer(elem(target_state.timer, 0))

      token = make_ref()
      timer = Process.send_after(self(), {:build, target, token}, state.debounce)

      put_target(state, target, %{
        target_state
        | timer: {timer, token}
      })
    end)
  end

  defp normalize_targets(:all, targets) do
    Enum.filter(@targets, &Map.has_key?(targets, &1))
  end

  defp normalize_targets(target, targets) when target in @targets,
    do: normalize_targets([target], targets)

  defp normalize_targets(requested, targets) when is_list(requested) do
    requested
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(targets, &1))
  end

  defp start_build(state, target, target_state) do
    build = state.build
    Logger.info("Building Rekindle #{target_label(target)}...")
    task = Task.async(fn -> build.(target, state.build_options) end)

    running = %{
      task: task,
      pid: task.pid,
      reference: task.ref,
      started_at: System.monotonic_time()
    }

    put_target(state, target, %{target_state | running: running, pending?: false})
  end

  defp finish_current(state, _target, target_state, {:ok, %Result{} = result}) do
    case state.activate.(result) do
      :ok ->
        {%{target_state | running: nil, last_success: result}, {:ok, result}}

      {:error, error} ->
        Rekindle.Development.Cleanup.discard(state.project, result)
        {%{target_state | running: nil}, {:error, error}}
    end
  end

  defp finish_current(_state, _target, target_state, {:error, error}) do
    {%{target_state | running: nil}, {:error, error}}
  end

  defp finish_current(_state, _target, target_state, other) do
    {%{target_state | running: nil}, {:error, {:invalid_build_result, other}}}
  end

  defp maybe_start_pending(state, target) do
    target_state = Map.fetch!(state.targets, target)

    if target_state.pending? and is_nil(target_state.timer) do
      target_state = %{target_state | pending?: false}
      start_build(state, target, target_state)
    else
      state
    end
  end

  defp running_target(targets, reference) do
    Enum.find_value(targets, fn {target, target_state} ->
      if target_state.running && target_state.running.reference == reference do
        {target, target_state}
      end
    end)
  end

  defp put_target(state, target, target_state) do
    put_in(state.targets[target], target_state)
  end

  defp target_state do
    %{timer: nil, running: nil, pending?: false, last_success: nil}
  end

  defp build(project, target, options) do
    Rekindle.Build.run(
      project,
      target,
      [profile: :dev, activate: false] ++ options
    )
  end

  defp activate(project, %Result{target: :web} = result),
    do: Rekindle.Web.Builder.activate(project, result)

  defp activate(_project, %Result{target: :desktop}), do: :ok

  defp notify(nil, _target, _result), do: :ok

  defp notify(destinations, target, result) when is_map(destinations) do
    case Map.fetch(destinations, target) do
      {:ok, destination} -> notify(destination, target, result)
      :error -> :ok
    end
  end

  defp notify(destination, target, result),
    do: send(destination, {__MODULE__, target, result})

  defp report(project, :web, {:ok, _result}, elapsed) do
    Rekindle.Development.State.clear_error(project)
    Logger.info("Built Rekindle Web in #{format_duration(elapsed)}")
  end

  defp report(project, :web, {:error, error}, elapsed) do
    Logger.error(
      "Rekindle Web build failed after #{format_duration(elapsed)}: #{error_message(error)}"
    )

    Rekindle.Development.State.put_error(project, error_message(error))
  end

  defp report(_project, :desktop, {:error, error}, elapsed) do
    Logger.error(
      "Rekindle desktop build failed after #{format_duration(elapsed)}: #{error_message(error)}"
    )
  end

  defp report(_project, :desktop, {:ok, _result}, elapsed) do
    Logger.info("Built Rekindle desktop in #{format_duration(elapsed)}")
  end

  defp elapsed(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp format_duration(milliseconds) when milliseconds < 1_000, do: "#{milliseconds}ms"

  defp format_duration(milliseconds) do
    seconds = milliseconds / 1_000
    "#{Float.round(seconds, 1)}s"
  end

  defp target_label(:web), do: "Web"
  defp target_label(:desktop), do: "desktop"

  defp error_message(error) do
    if is_exception(error), do: Exception.message(error), else: inspect(error)
  end
end
