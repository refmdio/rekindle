defmodule Rekindle.Development.Cleanup do
  @moduledoc false

  require Logger

  @retained 2
  @generation ~r/\A[0-9a-f]{64}\z/

  @spec startup(Rekindle.Config.t()) :: :ok
  def startup(project) do
    remove_owned_directory(Path.join([project.root, ".rekindle", "tmp"]))
    remove_temporary_markers(project.root)

    web_selected = selected_web(project.root)
    prune(Path.join([project.root, ".rekindle", "dev", "web"]), web_selected)

    desktop_root = Path.join([project.root, ".rekindle", "dev", "desktop"])
    desktop_selected = selected_desktop(project.root)

    desktop_root
    |> child_directories()
    |> Enum.each(fn directory ->
      target = Path.basename(directory)
      selected = if desktop_selected[:target] == target, do: desktop_selected[:generation]
      prune(directory, selected)
    end)

    :ok
  end

  @spec discard(Rekindle.Config.t(), Rekindle.Build.Result.t()) :: :ok
  def discard(project, %{target: :web, metadata: %{generation: generation, manifest: manifest}}) do
    selected = selected_web(project.root)

    if selected != generation, do: remove_owned_directory(Path.dirname(manifest))
    web(project, selected)
  end

  def discard(
        project,
        %{
          target: :desktop,
          metadata: %{generation: generation, manifest: manifest, rust_target: target}
        } = result
      ) do
    marker = selected_desktop(project.root)
    selected = if marker[:target] == target, do: marker[:generation]

    if selected != generation, do: remove_owned_directory(Path.dirname(manifest))
    desktop(project.root, result, selected)
  end

  def discard(_project, _result), do: :ok

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
      |> Enum.take(if(selected_path, do: @retained - 1, else: @retained))
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

  defp selected_web(root) do
    read_generation(Path.join([root, ".rekindle", "dev", "web-current.json"]))
  end

  defp selected_desktop(root) do
    path = Path.join([root, ".rekindle", "dev", "desktop-last-running.json"])

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"generation" => generation, "target" => target}}
          when is_binary(generation) and is_binary(target) ->
            if Regex.match?(@generation, generation) do
              %{generation: generation, target: target}
            else
              %{}
            end

          _other ->
            %{}
        end

      _error ->
        %{}
    end
  end

  defp read_generation(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"generation" => generation}} <- Jason.decode(contents),
         true <- is_binary(generation),
         true <- Regex.match?(@generation, generation) do
      generation
    else
      _error -> nil
    end
  end

  defp child_directories(root) do
    case File.ls(root) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(root, name)
          if match?({:ok, %{type: :directory}}, File.lstat(path)), do: [path], else: []
        end)

      _error ->
        []
    end
  end

  defp remove_owned_directory(path) do
    if match?({:ok, %{type: :directory}}, File.lstat(path)), do: remove(path)
  end

  defp remove_temporary_markers(root) do
    root
    |> Path.join(".rekindle/dev/*.tmp-*")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      if match?({:ok, %{type: :regular}}, File.lstat(path)), do: File.rm(path)
    end)
  end
end
