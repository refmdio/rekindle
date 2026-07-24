defmodule Rekindle.State do
  @moduledoc false

  @state_directory ".rekindle"

  @type reason ::
          File.posix()
          | {:outside_state, Path.t()}
          | {:unsafe_state_path, Path.t(), File.Stat.type()}

  @spec ensure_directory(Path.t(), Path.t()) :: :ok | {:error, reason()}
  def ensure_directory(project_root, path) do
    with {:ok, project_root, components} <- components(project_root, path) do
      ensure_components(project_root, components)
    end
  end

  @spec validate_directory(Path.t(), Path.t()) :: :ok | {:error, reason()}
  def validate_directory(project_root, path) do
    with {:ok, project_root, components} <- components(project_root, path) do
      validate_components(project_root, components)
    end
  end

  @spec validate_parent(Path.t(), Path.t()) :: :ok | {:error, reason()}
  def validate_parent(project_root, path) do
    validate_directory(project_root, Path.dirname(path))
  end

  @spec remove_directory(Path.t(), Path.t()) :: :ok | {:error, reason()}
  def remove_directory(project_root, path) do
    with :ok <- validate_parent(project_root, path) do
      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          case File.rm_rf(path) do
            {:ok, _removed} -> :ok
            {:error, reason, _file} -> {:error, reason}
          end

        {:ok, %{type: type}} ->
          {:error, {:unsafe_state_path, path, type}}

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec remove_file(Path.t(), Path.t()) :: :ok | {:error, reason()}
  def remove_file(project_root, path) do
    with :ok <- validate_parent(project_root, path) do
      case File.lstat(path) do
        {:ok, %{type: :regular}} -> File.rm(path)
        {:ok, %{type: type}} -> {:error, {:unsafe_state_path, path, type}}
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec format_error(reason()) :: String.t()
  def format_error({:outside_state, path}),
    do: "path is outside the project state directory: #{path}"

  def format_error({:unsafe_state_path, path, type}),
    do: "project state path is not a real directory or file: #{path} (#{type})"

  def format_error(reason) when is_atom(reason), do: List.to_string(:file.format_error(reason))

  defp components(project_root, path) do
    project_root = Path.expand(project_root)
    path = Path.expand(path)
    relative = Path.relative_to(path, project_root)
    components = Path.split(relative)

    if components != [] and hd(components) == @state_directory and
         Enum.all?(components, &safe_component?/1) do
      {:ok, project_root, components}
    else
      {:error, {:outside_state, path}}
    end
  end

  defp safe_component?(component), do: component not in ["", ".", ".."]

  defp ensure_components(root, components) do
    with :ok <- real_directory(root) do
      Enum.reduce_while(components, {:ok, root}, fn component, {:ok, parent} ->
        path = Path.join(parent, component)

        case ensure_component(path) do
          :ok -> {:cont, {:ok, path}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _path} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_components(root, components) do
    with :ok <- real_directory(root) do
      Enum.reduce_while(components, {:ok, root}, fn component, {:ok, parent} ->
        path = Path.join(parent, component)

        case real_directory(path) do
          :ok -> {:cont, {:ok, path}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _path} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_component(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, %{type: type}} ->
        {:error, {:unsafe_state_path, path, type}}

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok -> :ok
          {:error, :eexist} -> real_directory(path)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp real_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, %{type: type}} -> {:error, {:unsafe_state_path, path, type}}
      {:error, reason} -> {:error, reason}
    end
  end
end
