defmodule Rekindle.Cargo.Metadata do
  @moduledoc false

  alias Rekindle.Cargo.Error
  alias Rekindle.Toolchain.Process

  @enforce_keys [:packages, :workspace_members, :target_directory]
  defstruct [:packages, :workspace_members, :target_directory]

  @type package :: %{
          id: String.t(),
          name: String.t(),
          manifest_path: Path.t(),
          targets: [map()],
          dependencies: [String.t()]
        }

  @type t :: %__MODULE__{
          packages: [package()],
          workspace_members: MapSet.t(String.t()),
          target_directory: Path.t()
        }

  @spec load(Rekindle.Config.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def load(project, options \\ []) do
    executable = Rekindle.Toolchain.cargo_path(options)

    arguments =
      [
        "metadata",
        "--format-version",
        "1",
        "--no-deps",
        "--manifest-path",
        Path.join(project.client_root, "Cargo.toml")
      ] ++ if(Keyword.get(options, :locked, false), do: ["--locked"], else: [])

    case Process.run(executable, arguments, process_options(project, options)) do
      {:ok, %{truncated?: true}} ->
        {:error, Error.new(:output_limit, "cargo metadata exceeded the output limit")}

      {:ok, %{status: 0, output: output}} ->
        decode(output)

      {:ok, result} ->
        {:error,
         Error.new(:metadata_failed, "cargo metadata failed with status #{result.status}",
           output: result.output
         )}

      {:error, reason} ->
        process_error(:metadata_failed, "cargo metadata", reason)
    end
  end

  defp decode(output) do
    value =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        case Jason.decode(line) do
          {:ok, %{"packages" => _packages} = value} -> value
          _ -> nil
        end
      end)

    with %{} <- value,
         %{
           "packages" => packages,
           "workspace_members" => workspace_members,
           "target_directory" => target_directory
         } <- value do
      {:ok,
       %__MODULE__{
         packages: Enum.map(packages, &package/1),
         workspace_members: MapSet.new(workspace_members),
         target_directory: target_directory
       }}
    else
      _ ->
        {:error,
         Error.new(:invalid_metadata, "cargo metadata returned invalid JSON", output: output)}
    end
  end

  defp package(value) do
    %{
      id: value["id"],
      name: value["name"],
      manifest_path: value["manifest_path"],
      targets: value["targets"],
      dependencies: Enum.map(value["dependencies"], & &1["name"])
    }
  end

  defp process_options(project, options) do
    [
      cd: project.client_root,
      timeout: Keyword.get(options, :timeout, 120_000),
      output_limit: Keyword.get(options, :output_limit, 8_000_000),
      cancel_ref: Keyword.get(options, :cancel_ref),
      env: Keyword.get(options, :env, [])
    ]
  end

  defp process_error(kind, operation, :timeout),
    do: {:error, Error.new(kind, "#{operation} timed out")}

  defp process_error(kind, operation, :cancelled),
    do: {:error, Error.new(kind, "#{operation} was cancelled")}

  defp process_error(kind, operation, {:start, error}),
    do: {:error, Error.new(kind, "#{operation} could not start: #{Exception.message(error)}")}
end
