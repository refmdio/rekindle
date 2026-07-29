defmodule Rekindle.Check do
  @moduledoc false

  alias Rekindle.Cargo
  alias Rekindle.Cargo.{Error, Metadata}
  alias Rekindle.Config
  alias Rekindle.Toolchain
  alias Rekindle.Toolchain.Process

  @targets [:web, :desktop]

  @type status :: :start | :ok
  @type notifier :: (status(), String.t() -> any())

  @spec run(atom(), keyword()) :: :ok | {:error, Config.Error.t() | Error.t()}
  def run(otp_app, options \\ []) when is_atom(otp_app) do
    root = Keyword.get(options, :project_root, File.cwd!())

    with {:ok, project} <- Config.load(otp_app, project_root: root),
         {:ok, metadata} <- Metadata.load(project, Keyword.put(options, :locked, true)),
         {:ok, steps} <- steps(project, metadata, options) do
      execute(project, steps, options)
    end
  end

  defp steps(project, metadata, options) do
    manifest = Path.join(project.client_root, "Cargo.toml")

    format = %{
      label: "Rust formatting",
      arguments: ["fmt", "--all", "--manifest-path", manifest, "--", "--check"]
    }

    Enum.reduce_while(@targets, {:ok, []}, fn name, {:ok, target_steps} ->
      case Map.fetch(project.targets, name) do
        :error ->
          {:cont, {:ok, target_steps}}

        {:ok, target} ->
          with {:ok, package, binary} <- Cargo.resolve(metadata, project, target),
               {:ok, rust_target} <-
                 Toolchain.target(name, Keyword.put(options, :cd, project.client_root)) do
            common = [
              "--manifest-path",
              manifest,
              "--package",
              package.name,
              "--target",
              rust_target,
              "--locked"
            ]

            features = feature_arguments(target.features)

            clippy = %{
              label: "#{target_label(name)} clippy",
              arguments:
                List.flatten([
                  ["clippy"],
                  common,
                  ["--bin", binary],
                  features,
                  ["--", "-D", "warnings"]
                ])
            }

            {:cont, {:ok, [clippy | target_steps]}}
          else
            {:error, %Error{} = error} -> {:halt, {:error, error}}
            {:error, error} -> {:halt, {:error, Error.new(:target, Exception.message(error))}}
          end
      end
    end)
    |> case do
      {:ok, target_steps} -> {:ok, [format | Enum.reverse(target_steps)]}
      {:error, error} -> {:error, error}
    end
  end

  defp execute(project, steps, options) do
    cargo_options = Keyword.put(options, :cd, project.client_root)
    executable = Toolchain.cargo_path(cargo_options)
    notify = Keyword.get(options, :notify, fn _status, _label -> :ok end)

    Enum.reduce_while(steps, :ok, fn step, :ok ->
      notify.(:start, step.label)

      case Process.run(executable, step.arguments,
             cd: project.client_root,
             timeout: Keyword.get(options, :timeout, :infinity),
             output_limit: Keyword.get(options, :output_limit, 8_000_000),
             env: Toolchain.cargo_environment(cargo_options)
           ) do
        {:ok, %{status: 0}} ->
          notify.(:ok, step.label)
          {:cont, :ok}

        {:ok, result} ->
          {:halt,
           {:error,
            Error.new(:check_failed, "#{step.label} failed with status #{result.status}",
              output: result.output
            )}}

        {:error, reason} ->
          {:halt, {:error, process_error(step.label, reason)}}
      end
    end)
  end

  defp feature_arguments([]), do: []
  defp feature_arguments(features), do: ["--features", Enum.join(features, ",")]

  defp process_error(label, :timeout), do: Error.new(:timeout, "#{label} timed out")

  defp process_error(label, :output_limit),
    do: Error.new(:output_limit, "#{label} exceeded the output limit")

  defp process_error(label, {:start, error}),
    do: Error.new(:start_failed, "#{label} could not start: #{Exception.message(error)}")

  defp process_error(_label, {:invalid_option, option}),
    do: Error.new(:invalid_option, "invalid Rust check process option: #{option}")

  defp target_label(:web), do: "Web"
  defp target_label(:desktop), do: "Desktop"
end
