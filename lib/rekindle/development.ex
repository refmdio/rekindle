defmodule Rekindle.Development do
  @moduledoc false

  use Supervisor

  alias Rekindle.Config

  @targets [:web, :desktop]
  @registry Rekindle.Development.Registry
  @supervisor Rekindle.Development.DynamicSupervisor

  @doc false
  @spec ensure_started(keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(options) do
    otp_app = Keyword.fetch!(options, :otp_app)

    with {:ok, project} <-
           Config.load(otp_app,
             project_root: Keyword.get(options, :project_root, File.cwd!())
           ),
         {:ok, targets} <- targets(project, Keyword.get(options, :targets)) do
      identity = %{project_root: project.root, targets: targets}
      name = {:via, Registry, {@registry, otp_app, identity}}

      options =
        options
        |> Keyword.put(:project_root, project.root)
        |> Keyword.put(:targets, targets)
        |> Keyword.put(:name, name)

      case runtime(otp_app, identity) do
        :missing ->
          case DynamicSupervisor.start_child(@supervisor, {__MODULE__, options}) do
            {:error, {:already_started, _pid}} = error ->
              runtime_result(otp_app, identity, error)

            result ->
              result
          end

        result ->
          result
      end
    end
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    Supervisor.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @doc false
  @spec targets(Config.t(), nil | [atom()]) ::
          {:ok, [:web | :desktop]} | {:error, Config.Error.t()}
  def targets(project, nil) do
    if Map.has_key?(project.targets, :web), do: {:ok, [:web]}, else: {:ok, [:desktop]}
  end

  def targets(project, requested) when is_list(requested) do
    requested = Enum.uniq(requested)
    enabled = Map.keys(project.targets)

    if requested != [] and Enum.all?(requested, &(&1 in @targets and &1 in enabled)) do
      {:ok, Enum.filter(@targets, &(&1 in requested))}
    else
      {:error,
       Config.Error.new(
         :invalid_development_targets,
         "development targets must be a non-empty subset of enabled targets #{inspect(Enum.sort(enabled))}"
       )}
    end
  end

  @impl Supervisor
  def init(options) do
    otp_app = Keyword.fetch!(options, :otp_app)
    project_root = Keyword.get(options, :project_root, File.cwd!())

    with {:ok, project} <- Config.load(otp_app, project_root: project_root),
         {:ok, targets} <- targets(project, Keyword.get(options, :targets)),
         {:ok, metadata} <- Rekindle.Cargo.Metadata.load(project),
         :ok <- Rekindle.Development.Cleanup.startup(project, targets) do
      builder = process_name(otp_app, "Builder")
      file_system = process_name(otp_app, "FileSystem")
      core = process_name(otp_app, "Core")
      desktop_supervisor = process_name(otp_app, "DesktopSupervisor")
      desktop = process_name(otp_app, "Desktop")

      desktop_children =
        if :desktop in targets do
          [
            %{
              id: Rekindle.Desktop.Processes,
              start:
                {DynamicSupervisor, :start_link,
                 [[strategy: :one_for_one, name: desktop_supervisor]]},
              type: :supervisor
            },
            {Rekindle.Desktop.Development,
             name: desktop, project_root: project.root, supervisor: desktop_supervisor}
          ]
        else
          []
        end

      notifications = if :desktop in targets, do: %{desktop: desktop}, else: %{}

      children =
        desktop_children ++
          [
            {Rekindle.Development.Core,
             name: core,
             builder: builder,
             file_system: file_system,
             otp_app: otp_app,
             project_root: project.root,
             targets: targets,
             notify: notifications,
             client_root: project.client_root,
             target_directory: metadata.target_directory}
          ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      {:error, error} -> raise error
    end
  end

  defp process_name(otp_app, role) do
    app = otp_app |> Atom.to_string() |> Macro.camelize()
    Module.concat([__MODULE__, app, role])
  end

  defp runtime(otp_app, identity) do
    case Registry.lookup(@registry, otp_app) do
      [{pid, ^identity}] -> {:ok, pid}
      [{_pid, existing}] -> runtime_mismatch(identity, existing)
      [] -> :missing
    end
  end

  defp runtime_result(otp_app, identity, error) do
    case runtime(otp_app, identity) do
      :missing -> error
      result -> result
    end
  end

  defp runtime_mismatch(requested, existing) do
    {:error,
     Config.Error.new(
       :development_runtime_mismatch,
       "development runtime is already running for #{inspect(existing.targets)} at #{existing.project_root}; " <>
         "stop it before requesting #{inspect(requested.targets)} at #{requested.project_root}"
     )}
  end
end
