defmodule Rekindle.Test do
  @moduledoc """
  Runs the Rust tests for a configured Rekindle client.

  The configured Cargo packages are tested once each with Cargo's standard
  test selection. This includes unit tests, integration tests, and doctests.
  """

  alias Rekindle.Cargo
  alias Rekindle.Cargo.{Error, Metadata}
  alias Rekindle.Config
  alias Rekindle.Toolchain
  alias Rekindle.Toolchain.Process

  @type status :: :start | :ok
  @type notifier :: (status(), String.t() -> any())

  @spec run(atom(), keyword()) :: :ok | {:error, Config.Error.t() | Error.t()}
  def run(otp_app, options \\ []) when is_atom(otp_app) do
    root = Keyword.get(options, :project_root, File.cwd!())

    with {:ok, project} <- Config.load(otp_app, project_root: root),
         cargo_options <- cargo_options(project, options),
         {:ok, metadata} <-
           Metadata.load(project, cargo_options |> Keyword.put(:locked, true)),
         {:ok, packages} <- packages(project, metadata) do
      execute(project, packages, cargo_options)
    end
  end

  @spec run!(atom(), keyword()) :: :ok
  def run!(otp_app, options \\ []) when is_atom(otp_app) do
    case run(otp_app, options) do
      :ok ->
        :ok

      {:error, %{output: output} = error} when output != "" ->
        raise %{error | message: Exception.message(error) <> "\n\n" <> output}

      {:error, error} ->
        raise error
    end
  end

  defp packages(project, metadata) do
    project.targets
    |> Map.values()
    |> Enum.reduce_while({:ok, %{}}, fn target, {:ok, packages} ->
      case Cargo.resolve(metadata, project, target) do
        {:ok, package, _binary} ->
          {:cont, {:ok, Map.put(packages, package.id, package)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, packages} ->
        {:ok, packages |> Map.values() |> Enum.sort_by(& &1.name)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp execute(project, packages, options) do
    executable = Toolchain.cargo_path(options)
    notify = Keyword.get(options, :notify, fn _status, _label -> :ok end)
    manifest = Path.join(project.client_root, "Cargo.toml")

    Enum.reduce_while(packages, :ok, fn package, :ok ->
      label = "Rust tests for #{package.name}"
      notify.(:start, label)

      arguments = [
        "test",
        "--manifest-path",
        manifest,
        "--package",
        package.name,
        "--locked"
      ]

      case Process.run(executable, arguments,
             cd: project.client_root,
             timeout: Keyword.get(options, :timeout, :infinity),
             output_limit: Keyword.get(options, :output_limit, 8_000_000),
             env: Keyword.fetch!(options, :env)
           ) do
        {:ok, %{status: 0}} ->
          notify.(:ok, label)
          {:cont, :ok}

        {:ok, result} ->
          {:halt,
           {:error,
            Error.new(:test_failed, "#{label} failed with status #{result.status}",
              output: result.output
            )}}

        {:error, reason} ->
          {:halt, {:error, process_error(label, reason)}}
      end
    end)
  end

  defp cargo_options(project, options) do
    options
    |> Keyword.put(:cd, project.client_root)
    |> then(fn options ->
      Keyword.put(options, :env, Toolchain.cargo_environment(options))
    end)
  end

  defp process_error(label, :timeout), do: Error.new(:timeout, "#{label} timed out")

  defp process_error(label, :output_limit),
    do: Error.new(:output_limit, "#{label} exceeded the output limit")

  defp process_error(label, {:start, error}),
    do: Error.new(:start_failed, "#{label} could not start: #{Exception.message(error)}")

  defp process_error(_label, {:invalid_option, option}),
    do: Error.new(:invalid_option, "invalid Rust test process option: #{option}")
end
