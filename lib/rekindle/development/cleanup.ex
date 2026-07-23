defmodule Rekindle.Development.Cleanup do
  @moduledoc false

  require Logger

  @retained 2
  @generation ~r/\A[0-9a-f]{64}\z/

  @spec web(Rekindle.Config.t(), String.t()) :: :ok
  def web(project, generation) do
    prune(Path.join([project.root, ".rekindle", "dev", "web"]), generation)
  end

  @spec desktop(Path.t(), Rekindle.Build.Result.t()) :: :ok
  def desktop(root, result) do
    desktop(root, result, result.metadata.generation)
  end

  @spec desktop(Path.t(), Rekindle.Build.Result.t(), String.t()) :: :ok
  def desktop(root, result, selected_generation) do
    directory =
      Path.join([
        root,
        ".rekindle",
        "dev",
        "desktop",
        result.metadata.rust_target
      ])

    prune(directory, selected_generation)
  end

  defp prune(directory, selected) do
    directory
    |> generations()
    |> Enum.sort_by(fn {_path, modified} -> modified end, :desc)
    |> keep(selected)
    |> Enum.each(&remove/1)

    :ok
  end

  defp generations(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(directory, name)

          with true <- Regex.match?(@generation, name),
               {:ok, %{type: :directory, mtime: modified}} <- File.stat(path, time: :posix),
               {:ok, %{type: :directory}} <- File.lstat(path) do
            [{path, modified}]
          else
            _error -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp keep(generations, selected) do
    selected_path = Enum.find(generations, &(Path.basename(elem(&1, 0)) == selected))

    retained =
      generations
      |> Enum.reject(&(&1 == selected_path))
      |> Enum.take(@retained - 1)
      |> then(fn recent -> if selected_path, do: [selected_path | recent], else: recent end)
      |> MapSet.new(&elem(&1, 0))

    generations
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&MapSet.member?(retained, &1))
  end

  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, file} -> Logger.warning("could not remove #{file}: #{inspect(reason)}")
    end
  end
end
