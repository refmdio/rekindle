defmodule Rekindle.Cargo do
  @moduledoc false

  alias Rekindle.Cargo.{Error, Messages, Metadata}
  alias Rekindle.Config.Target
  alias Rekindle.Diagnostic
  alias Rekindle.Toolchain.Process

  @web_target "wasm32-unknown-unknown"

  @enforce_keys [:artifact, :package, :binary, :target_directory, :diagnostics]
  defstruct [:artifact, :package, :binary, :target_directory, :diagnostics, output: ""]

  @type t :: %__MODULE__{
          artifact: Path.t(),
          package: String.t(),
          binary: String.t(),
          target_directory: Path.t(),
          diagnostics: [Diagnostic.t()],
          output: String.t()
        }

  @spec build(Rekindle.Config.t(), Target.t(), :dev | :release, keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def build(project, %Target{} = target, profile, options \\ []) do
    with {:ok, metadata} <- Metadata.load(project, options),
         {:ok, package, binary} <- resolve(metadata, project, target),
         {:ok, process} <- execute(project, target, profile, package, binary, options),
         {:ok, artifact, diagnostics, output} <-
           Messages.decode(process, package.id, binary, target.name) do
      {:ok,
       %__MODULE__{
         artifact: artifact,
         package: package.name,
         binary: binary,
         target_directory: metadata.target_directory,
         diagnostics: diagnostics,
         output: output
       }}
    end
  end

  @spec resolve(Metadata.t(), Rekindle.Config.t(), Target.t()) ::
          {:ok, Metadata.package(), String.t()} | {:error, Error.t()}
  def resolve(metadata, project, target) do
    workspace_packages =
      Enum.filter(metadata.packages, &MapSet.member?(metadata.workspace_members, &1.id))

    with {:ok, package} <- package(workspace_packages, target.package),
         {:ok, binary} <- binary(package, project, target) do
      {:ok, package, binary}
    end
  end

  defp package(packages, nil) do
    case packages do
      [package] ->
        {:ok, package}

      [] ->
        error(:package_not_found, "Cargo metadata contains no workspace package")

      _ ->
        names = packages |> Enum.map(& &1.name) |> Enum.sort()

        error(
          :ambiguous_package,
          "multiple Cargo packages are available; configure :package from #{inspect(names)}"
        )
    end
  end

  defp package(packages, name) do
    case Enum.filter(packages, &(&1.name == name)) do
      [package] ->
        {:ok, package}

      [] ->
        error(:package_not_found, "Cargo package #{inspect(name)} was not found in the workspace")
    end
  end

  defp binary(package, project, target) do
    expected_entry = Path.join(project.root, target.entry) |> Path.expand()

    candidates =
      Enum.filter(package.targets, fn candidate ->
        "bin" in candidate["kind"] and
          (is_nil(target.binary) or candidate["name"] == target.binary) and
          Path.expand(candidate["src_path"]) == expected_entry
      end)

    case candidates do
      [candidate] ->
        {:ok, candidate["name"]}

      [] ->
        error(
          :binary_not_found,
          "Cargo package #{inspect(package.name)} has no binary for #{target.entry}"
        )

      _ ->
        error(:ambiguous_binary, "Cargo metadata returned multiple binaries for #{target.entry}")
    end
  end

  defp execute(project, target, profile, package, binary, options) do
    executable = Rekindle.Toolchain.cargo_path(options)

    arguments =
      [
        "build",
        "--manifest-path",
        Path.join(project.client_root, "Cargo.toml"),
        "--message-format=json-render-diagnostics",
        "--package",
        package.name,
        "--bin",
        binary,
        "--profile",
        Map.fetch!(target.profiles, profile)
      ]
      |> target_arguments(target.name)
      |> feature_arguments(target.features)

    process_options = [
      cd: project.root,
      timeout: Keyword.get(options, :timeout, 120_000),
      output_limit: Keyword.get(options, :output_limit, 8_000_000),
      cancel_ref: Keyword.get(options, :cancel_ref),
      env: Keyword.get(options, :env, [])
    ]

    case Process.run(executable, arguments, process_options) do
      {:ok, result} ->
        {:ok, result}

      {:error, :timeout} ->
        error(:timeout, "cargo build timed out")

      {:error, :cancelled} ->
        error(:cancelled, "cargo build was cancelled")

      {:error, {:start, reason}} ->
        error(:start_failed, "cargo build could not start: #{Exception.message(reason)}")
    end
  end

  defp target_arguments(arguments, :web), do: arguments ++ ["--target", @web_target]
  defp target_arguments(arguments, :desktop), do: arguments

  defp feature_arguments(arguments, []), do: arguments

  defp feature_arguments(arguments, features),
    do: arguments ++ ["--features", Enum.join(features, ",")]

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
