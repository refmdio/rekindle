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
         {:ok, packages} <- packages(value["packages"]),
         workspace_members when is_list(workspace_members) <- value["workspace_members"],
         true <- Enum.all?(workspace_members, &non_empty_string?/1),
         target_directory when is_binary(target_directory) and target_directory != "" <-
           value["target_directory"] do
      {:ok,
       %__MODULE__{
         packages: packages,
         workspace_members: MapSet.new(workspace_members),
         target_directory: target_directory
       }}
    else
      _ -> invalid_metadata(output)
    end
  end

  defp packages(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, packages} ->
      case package(value) do
        {:ok, package} -> {:cont, {:ok, [package | packages]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, packages} -> {:ok, Enum.reverse(packages)}
      :error -> :error
    end
  end

  defp packages(_values), do: :error

  defp package(value) do
    with %{} <- value,
         id when is_binary(id) and id != "" <- value["id"],
         name when is_binary(name) and name != "" <- value["name"],
         manifest_path when is_binary(manifest_path) and manifest_path != "" <-
           value["manifest_path"],
         {:ok, targets} <- targets(value["targets"]),
         {:ok, dependencies} <- dependencies(value["dependencies"]) do
      {:ok,
       %{
         id: id,
         name: name,
         manifest_path: manifest_path,
         targets: targets,
         dependencies: dependencies
       }}
    else
      _ -> :error
    end
  end

  defp targets(values) when is_list(values) do
    if Enum.all?(values, &target?/1), do: {:ok, values}, else: :error
  end

  defp targets(_values), do: :error

  defp target?(value) when is_map(value) do
    non_empty_string?(value["name"]) and
      non_empty_string?(value["src_path"]) and
      is_list(value["kind"]) and
      Enum.all?(value["kind"], &is_binary/1)
  end

  defp target?(_value), do: false

  defp dependencies(values) when is_list(values) do
    if Enum.all?(values, &dependency?/1) do
      {:ok, Enum.map(values, & &1["name"])}
    else
      :error
    end
  end

  defp dependencies(_values), do: :error

  defp dependency?(value) when is_map(value), do: non_empty_string?(value["name"])
  defp dependency?(_value), do: false

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp invalid_metadata(output) do
    {:error, Error.new(:invalid_metadata, "cargo metadata returned invalid JSON", output: output)}
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
