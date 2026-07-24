defmodule Rekindle do
  use Supervisor

  @moduledoc """
  Mix-first tooling for Rust UI applications in Elixir and Phoenix projects.
  """

  alias Rekindle.Config

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(options) do
    otp_app = Keyword.fetch!(options, :otp_app)
    endpoint = Keyword.fetch!(options, :endpoint)

    if Application.get_env(otp_app, endpoint, [])[:code_reloader] == true do
      Supervisor.start_link(__MODULE__, options)
    else
      :ignore
    end
  end

  @impl Supervisor
  def init(options) do
    otp_app = Keyword.fetch!(options, :otp_app)
    project_root = Keyword.get(options, :project_root, File.cwd!())

    with {:ok, project} <- Config.load(otp_app, project_root: project_root),
         {:ok, metadata} <- Rekindle.Cargo.Metadata.load(project),
         :ok <- Rekindle.Development.Cleanup.startup(project) do
      builder = process_name(otp_app, "Builder")
      file_system = process_name(otp_app, "FileSystem")
      desktop_supervisor = process_name(otp_app, "DesktopSupervisor")
      desktop = process_name(otp_app, "Desktop")

      desktop_children =
        if Map.has_key?(project.targets, :desktop) do
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

      notifications = if Map.has_key?(project.targets, :desktop), do: [desktop], else: []

      children =
        desktop_children ++
          [
            {Rekindle.Development.Builder,
             name: builder, otp_app: otp_app, project_root: project.root, notify: notifications},
            %{
              id: Rekindle.Development.FileSystem,
              start: {FileSystem, :start_link, [[dirs: [project.client_root], name: file_system]]}
            },
            {Rekindle.Development.Watcher,
             source: file_system,
             builder: builder,
             root: project.client_root,
             target_directory: metadata.target_directory}
          ]

      Supervisor.init(children, strategy: :rest_for_one)
    else
      {:error, error} ->
        raise error
    end
  end

  defp process_name(otp_app, role) do
    app = otp_app |> Atom.to_string() |> Macro.camelize()
    Module.concat([Rekindle.Development, app, role])
  end

  @doc """
  Builds artifacts for an enabled target.

  The owning OTP application must be supplied with `:otp_app`. The optional
  `:profile` is either `:dev` or `:release`; it defaults to `:dev`.
  """
  @spec build(:web | :desktop, keyword()) ::
          {:ok, Rekindle.Build.Result.t()}
          | {:error,
             Config.Error.t()
             | Rekindle.Build.Error.t()
             | Rekindle.Cargo.Error.t()
             | Rekindle.Desktop.Error.t()
             | Rekindle.Toolchain.Error.t()
             | Rekindle.Web.Error.t()}
  def build(target, options \\ []) do
    with {:ok, otp_app} <- fetch_otp_app(options),
         {:ok, project} <- Config.load(otp_app, options) do
      Rekindle.Build.run(project, target, options)
    end
  end

  defp fetch_otp_app(options) do
    case Keyword.fetch(options, :otp_app) do
      {:ok, otp_app} when is_atom(otp_app) ->
        {:ok, otp_app}

      _ ->
        {:error,
         Rekindle.Build.Error.new(
           :missing_otp_app,
           "expected :otp_app to name the application that owns the Rekindle configuration"
         )}
    end
  end
end
