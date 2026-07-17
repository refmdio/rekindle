defmodule Rekindle.ProjectSupervisor do
  @moduledoc false

  use Supervisor

  alias Rekindle.Config

  def start_link(options) do
    otp_app = Keyword.fetch!(options, :otp_app)

    case Config.load(otp_app) do
      {:ok, project} ->
        Supervisor.start_link(__MODULE__, project, name: Keyword.fetch!(options, :name))

      {:error, errors} ->
        {:error, {:configuration, errors}}
    end
  end

  @impl true
  def init(project) do
    children = [
      {Rekindle.EventBus, otp_app: project.otp_app},
      {Rekindle.RuntimeState, project: project}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
