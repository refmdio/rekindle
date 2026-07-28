defmodule Rekindle.Development.Core do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    Supervisor.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @impl Supervisor
  def init(options) do
    builder = Keyword.fetch!(options, :builder)
    file_system = Keyword.fetch!(options, :file_system)
    client_root = Keyword.fetch!(options, :client_root)

    children = [
      {Rekindle.Development.Builder,
       name: builder,
       otp_app: Keyword.fetch!(options, :otp_app),
       project_root: Keyword.fetch!(options, :project_root),
       targets: Keyword.fetch!(options, :targets),
       notify: Keyword.fetch!(options, :notify)},
      %{
        id: Rekindle.Development.FileSystem,
        start: {FileSystem, :start_link, [[dirs: [client_root], name: file_system]]}
      },
      {Rekindle.Development.Watcher,
       source: file_system,
       builder: builder,
       root: client_root,
       target_directory: Keyword.fetch!(options, :target_directory)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
