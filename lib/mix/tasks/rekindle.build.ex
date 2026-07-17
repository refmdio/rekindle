defmodule Mix.Tasks.Rekindle.Build do
  @shortdoc "Build and seal one Rekindle target"

  use Mix.Task

  @grammar [switches: [release: :boolean, json: :boolean], positionals: 1]

  @impl Mix.Task
  def run(argv) do
    argv
    |> run_outcome()
    |> Rekindle.Command.emit_and_exit()
  end

  @doc false
  def run_outcome(argv, options \\ []) do
    build = Keyword.get(options, :build, &Rekindle.build/3)

    load_otp_app =
      case Keyword.fetch(options, :otp_app) do
        {:ok, otp_app} -> fn -> otp_app end
        :error -> fn -> Mix.Project.config()[:app] end
      end

    Rekindle.Command.run("rekindle.build", argv, @grammar, fn invocation ->
      with {:ok, target} <- target(invocation.positionals),
           mode <- if(Map.get(invocation.options, :release, false), do: :release, else: :dev) do
        build.(load_otp_app.(), target, mode: mode)
      end
    end)
  end

  defp target(["web"]), do: {:ok, :web}
  defp target(["desktop"]), do: {:ok, :desktop}

  defp target(_positionals) do
    {:error, :invocation,
     Rekindle.Failure.new!(
       target: nil,
       stage: :configuration,
       code: :target_undeclared,
       message: "Build target must be web or desktop"
     )}
  end
end
