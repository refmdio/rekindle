defmodule Mix.Tasks.Rekindle.Doctor do
  use Mix.Task

  @shortdoc "Checks Rekindle configuration and prerequisites"

  @impl Mix.Task
  def run(arguments) do
    if arguments != [], do: Mix.raise("usage: mix rekindle.doctor")
    otp_app = Mix.Project.config()[:app]

    case Rekindle.Doctor.run(otp_app, project_root: File.cwd!()) do
      {:ok, checks} ->
        print(checks)

      {:error, checks} ->
        print(checks)
        Mix.raise("Rekindle Doctor found errors")
    end
  end

  defp print(checks) do
    Enum.each(checks, fn check ->
      marker = if check.status == :error, do: "error", else: "ok"
      Mix.shell().info("[#{marker}] #{check.message}")
    end)
  end
end
