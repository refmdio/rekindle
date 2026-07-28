if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Rekindle.Install do
    @shortdoc "Install Rekindle into a Phoenix project"
    @moduledoc """
    Installs Rekindle into a Phoenix project through Igniter.

        mix igniter.install rekindle --plugin gpui --targets web,desktop

    Valid plugins are `gpui`, `egui`, and `slint`. Targets can be `web`,
    `desktop`, or both. The installer creates `client/` and does not overwrite
    an existing Rust project.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :rekindle,
        example: "mix igniter.install rekindle --plugin gpui --targets web,desktop",
        schema: [plugin: :string, targets: :csv]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      Rekindle.Install.run(igniter, igniter.args.options)
    end
  end
else
  defmodule Mix.Tasks.Rekindle.Install do
    @shortdoc "Install Rekindle into a Phoenix project"
    @moduledoc false

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.raise("rekindle.install requires Igniter; run mix igniter.install rekindle")
    end
  end
end
