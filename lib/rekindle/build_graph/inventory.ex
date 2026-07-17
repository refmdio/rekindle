defmodule Rekindle.BuildGraph.Inventory do
  @moduledoc false

  alias Rekindle.Failure

  @fixed_exclusions ~w[.git _build deps .rekindle]

  @enforce_keys [:project_root, :excluded_roots, :direct_inputs]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          project_root: Path.t(),
          excluded_roots: [String.t()],
          direct_inputs: [map()]
        }

  @spec scan(Path.t(), [String.t()]) :: {:ok, t()} | {:error, Failure.t()}
  def scan(project_root, extra_exclusions \\ [])

  def scan(project_root, extra_exclusions)
      when is_binary(project_root) and is_list(extra_exclusions) do
    with :ok <- validate_root(project_root),
         {:ok, exclusions} <- normalize_exclusions(extra_exclusions),
         {:ok, inputs} <- walk(project_root, ".", exclusions) do
      {:ok,
       %__MODULE__{
         project_root: project_root,
         excluded_roots: exclusions,
         direct_inputs: Enum.sort_by(inputs, &input_sort_key/1)
       }}
    end
  rescue
    _ -> failure(:io_failed, "Project input inventory could not be read")
  end

  def scan(_project_root, _extra_exclusions),
    do: failure(:path_invalid, "Project input inventory configuration is invalid")

  defp validate_root(root) do
    with true <- Path.type(root) == :absolute,
         true <- Path.expand(root) == root,
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root) do
      :ok
    else
      _ -> failure(:path_invalid, "Project root must be an existing canonical directory")
    end
  end

  defp normalize_exclusions(extra) do
    extra
    |> Enum.reduce_while({:ok, @fixed_exclusions}, fn path, {:ok, acc} ->
      if relative_path?(path),
        do: {:cont, {:ok, [path | acc]}},
        else: {:halt, failure(:path_invalid, "Excluded root is not project-relative")}
    end)
    |> case do
      {:ok, values} ->
        values = values |> Enum.uniq() |> Enum.sort()

        if redundant_exclusions?(values),
          do: failure(:path_overlap, "Excluded roots overlap"),
          else: {:ok, values}

      {:error, _} = error ->
        error
    end
  end

  defp redundant_exclusions?(values) do
    Enum.any?(values, fn left ->
      Enum.any?(values, fn right -> left != right and descendant_relative?(right, left) end)
    end)
  end

  defp walk(root, relative, exclusions) do
    absolute = if relative == ".", do: root, else: Path.join(root, relative)

    with {:ok, names} <- File.ls(absolute) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
        child = if relative == ".", do: name, else: relative <> "/" <> name

        if excluded?(child, exclusions) do
          {:cont, {:ok, acc}}
        else
          case inventory_entry(root, child, exclusions) do
            {:ok, entries} -> {:cont, {:ok, entries ++ acc}}
            {:error, _} = error -> {:halt, error}
          end
        end
      end)
      |> case do
        {:ok, []} when relative != "." ->
          {:ok, [%{"kind" => "empty_directory", "path" => relative}]}

        result ->
          result
      end
    else
      _ -> failure(:io_failed, "Project input directory could not be read")
    end
  end

  defp inventory_entry(root, relative, exclusions) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        walk(root, relative, exclusions)

      {:ok, %File.Stat{type: :regular} = before} ->
        hash_file(path, relative, before)

      {:ok, %File.Stat{type: :symlink}} ->
        failure(:path_invalid, "Project inputs cannot contain symbolic links")

      {:ok, _other} ->
        failure(:path_invalid, "Project inputs must be regular files or directories")

      {:error, _reason} ->
        failure(:io_failed, "Project input could not be inspected")
    end
  end

  defp hash_file(path, relative, before) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %File.Stat{type: :regular} = after_read} <- File.lstat(path),
         true <- stable_file?(before, after_read, bytes) do
      {:ok,
       [
         %{
           "kind" => "file",
           "path" => relative,
           "file_kind" => "data",
           "sha256" => sha256(bytes),
           "size" => byte_size(bytes)
         }
       ]}
    else
      false -> failure(:artifact_changed, "Project input changed while it was inventoried")
      _ -> failure(:io_failed, "Project input could not be read")
    end
  end

  defp stable_file?(before, after_read, bytes) do
    before.inode == after_read.inode and before.major_device == after_read.major_device and
      before.minor_device == after_read.minor_device and
      before.size == after_read.size and before.mtime == after_read.mtime and
      after_read.size == byte_size(bytes)
  end

  defp excluded?(relative, exclusions) do
    Enum.any?(exclusions, &(relative == &1 or descendant_relative?(relative, &1)))
  end

  defp descendant_relative?(path, parent), do: String.starts_with?(path, parent <> "/")

  defp input_sort_key(%{"kind" => "file", "path" => path}), do: {"file", path}

  defp input_sort_key(%{"kind" => "empty_directory", "path" => path}),
    do: {"empty_directory", path}

  defp relative_path?(value) when is_binary(value) do
    segments = String.split(value, "/")

    byte_size(value) in 1..4_096 and String.valid?(value) and
      String.normalize(value, :nfc) == value and Path.type(value) == :relative and
      not String.contains?(value, ["\\", <<0>>]) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/, value) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp relative_path?(_value), do: false
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp failure(code, message) do
    {:error,
     Failure.new!(
       target: nil,
       stage: elem(Failure.stage_for(code), 1),
       code: code,
       message: message
     )}
  end
end
