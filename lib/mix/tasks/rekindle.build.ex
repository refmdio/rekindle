defmodule Mix.Tasks.Rekindle.Build do
  use Mix.Task

  @shortdoc "Builds Web or desktop artifacts"
  @diagnostic_limit 64_000

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
        print_diagnostics(error)
        Mix.raise(Exception.message(error))
    end
  end

  defp print_diagnostics(%Rekindle.Cargo.Error{} = error) do
    rendered =
      case error.diagnostics do
        [] ->
          error.output

        diagnostics ->
          diagnostics
          |> Enum.map(&(&1.rendered || &1.message))
          |> Enum.join("\n")
      end

    if rendered != "" do
      Mix.shell().error(limit(rendered))
    end
  end

  defp print_diagnostics(%{output: output}) when is_binary(output) and output != "" do
    Mix.shell().error(limit(output))
  end

  defp print_diagnostics(_error), do: :ok

  defp limit(text) do
    if byte_size(text) > @diagnostic_limit do
      marker = "\n[diagnostics truncated]"
      prefix_size = @diagnostic_limit - byte_size(marker)

      text
      |> binary_part(0, prefix_size)
      |> valid_prefix()
      |> Kernel.<>(marker)
    else
      text
    end
  end

  defp valid_prefix(text) do
    if String.valid?(text) do
      text
    else
      valid_prefix(binary_part(text, 0, byte_size(text) - 1))
    end
  end

  defp parse_target(["web"]), do: :web
  defp parse_target(["desktop"]), do: :desktop
  defp parse_target(_), do: Mix.raise("usage: mix rekindle.build web|desktop [--release]")
end
