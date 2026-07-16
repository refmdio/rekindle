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

  @spec snapshot(atom() | String.t()) :: {:ok, map()} | :none
  def snapshot(project_root) do
    key = {:project, Path.expand(to_string(project_root))}

    case Registry.lookup(Rekindle.RuntimeRegistry, key) do
      [{pid, _value}] -> GenServer.call(pid, :snapshot)
      [] -> :none
    end
  end

  @impl true
  def init(project), do: {:ok, %__MODULE__{project: project}}

  @impl true
  def handle_call(:snapshot, _from, state) do
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
end
