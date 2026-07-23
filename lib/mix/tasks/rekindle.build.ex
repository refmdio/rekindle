defmodule Mix.Tasks.Rekindle.Build do
  use Mix.Task

  @shortdoc "Builds Web or desktop artifacts"

  @impl Mix.Task
  def run(arguments) do
    {options, positional, invalid} =
      OptionParser.parse(arguments, strict: [release: :boolean])

    if invalid != [] do
      Mix.raise("unknown options: #{inspect(invalid)}")
    end

    target = parse_target(positional)
    profile = if options[:release], do: :release, else: :dev
    otp_app = Mix.Project.config()[:app]

    case Rekindle.build(target, otp_app: otp_app, project_root: File.cwd!(), profile: profile) do
      {:ok, result} ->
        Mix.shell().info("Built #{target} artifacts: #{inspect(result)}")

      {:error, error} ->
        Mix.raise(Exception.message(error))
    end
  end

  defp parse_target(["web"]), do: :web
  defp parse_target(["desktop"]), do: :desktop
  defp parse_target(_), do: Mix.raise("usage: mix rekindle.build web|desktop [--release]")
end
