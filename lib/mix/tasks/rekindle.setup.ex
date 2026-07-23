defmodule Mix.Tasks.Rekindle.Setup do
  use Mix.Task

  @shortdoc "Installs declared Rust UI prerequisites"

  @impl Mix.Task
  def run(arguments) do
    selection = parse_selection(arguments)
    otp_app = Mix.Project.config()[:app]

    case Rekindle.Setup.run(otp_app, selection, project_root: File.cwd!()) do
      {:ok, checks} ->
        print(checks)

      {:error, checks} ->
        print(checks)
        Mix.raise("Rekindle setup failed")
    end
  end

  defp parse_selection([]), do: :enabled
  defp parse_selection(["web"]), do: :web
  defp parse_selection(["desktop"]), do: :desktop
  defp parse_selection(["all"]), do: :all
  defp parse_selection(_), do: Mix.raise("usage: mix rekindle.setup [web|desktop|all]")

  defp print(checks) do
    Enum.each(checks, fn check ->
      marker = if check.status == :error, do: "error", else: "ok"
      Mix.shell().info("[#{marker}] #{check.message}")
    end)
  end
end
