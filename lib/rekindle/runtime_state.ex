defmodule Rekindle.RuntimeState do
  @moduledoc false

  use GenServer

  defstruct [:project, status: :idle, targets: %{}, owned_processes: %{}]

  def start_link(options) do
    project = Keyword.fetch!(options, :project)
    key = {:project, project.project_root}

    GenServer.start_link(__MODULE__, project,
      name: {:via, Registry, {Rekindle.RuntimeRegistry, key}}
    )
  end

  @spec snapshot(Rekindle.otp_app(), String.t()) :: {:ok, map()} | :none
  def snapshot(otp_app, project_root) do
    case lookup(project_root) do
      [{pid, _value}] -> GenServer.call(pid, {:snapshot, otp_app})
      [] -> :none
    end
  end

  @spec current(Rekindle.otp_app(), String.t(), Rekindle.target()) ::
          {:ok, Rekindle.GenerationRef.t()} | :none
  def current(otp_app, project_root, target) when target in [:web, :desktop] do
    case lookup(project_root) do
      [{pid, _value}] -> GenServer.call(pid, {:current, otp_app, target})
      [] -> :none
    end
  end

  @spec put_current(GenServer.server(), Rekindle.GenerationRef.t()) :: :ok
  def put_current(server, %Rekindle.GenerationRef{} = generation) do
    GenServer.call(server, {:put_current, generation})
  end

  @impl true
  def init(project), do: {:ok, %__MODULE__{project: project}}

  @impl true
  def handle_call({:snapshot, otp_app}, _from, %{project: %{otp_app: otp_app}} = state) do
    {:reply,
     {:ok,
      %{
        otp_app: state.project.otp_app,
        project_root: state.project.project_root,
        status: state.status,
        target_count: map_size(state.targets),
        owned_process_count: map_size(state.owned_processes)
      }}, state}
  end

  def handle_call({:snapshot, _otp_app}, _from, state), do: {:reply, :none, state}

  def handle_call(
        {:current, otp_app, target},
        _from,
        %{project: %{otp_app: otp_app}} = state
      ) do
    reply =
      case Map.get(state.targets, target) do
        %{current: %Rekindle.GenerationRef{} = generation} -> {:ok, generation}
        _ -> :none
      end

    {:reply, reply, state}
  end

  def handle_call({:current, _otp_app, _target}, _from, state), do: {:reply, :none, state}

  def handle_call(
        {:put_current, %Rekindle.GenerationRef{target: target} = generation},
        _from,
        state
      ) do
    targets =
      Map.update(
        state.targets,
        target,
        %{current: generation},
        &Map.put(&1, :current, generation)
      )

    {:reply, :ok, %{state | targets: targets}}
  end

  defp lookup(project_root) do
    key = {:project, Path.expand(to_string(project_root))}
    Registry.lookup(Rekindle.RuntimeRegistry, key)
  end
end
