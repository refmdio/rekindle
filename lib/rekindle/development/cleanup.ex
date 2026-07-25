defmodule Rekindle.Development.Cleanup do
  @moduledoc false

  require Logger

  alias Rekindle.Publication
  alias Rekindle.OwnedPath

  @retained 2
  @generation ~r/\A[0-9a-f]{64}\z/
  @desktop_lock {:desktop, :dev}

  @spec startup(Rekindle.Config.t()) :: :ok
  def startup(project) do
    state_root = Path.join(project.root, ".rekindle")

    case OwnedPath.validate_directory(project.root, state_root) do
      :ok -> startup_owned(project)
      {:error, :enoent} -> :ok
      {:error, reason} -> warn_unsafe(reason)
    end
  end

  defp startup_owned(project) do
    cleanup_staging(project, :web)
    cleanup_staging(project, :desktop)
    remove_empty_tmp_root(project.root)

    with_cleanup_lock(project, {:web, :dev}, fn ->
      remove_temporary_markers(project.root, ".tmp-web-current-")
      remove_temporary_markers(project.root, ".tmp-web-error-")
      web_selected = selected_web(project.root)
      prune(project.root, Path.join([project.root, ".rekindle", "dev", "web"]), web_selected)
    end)

    with_cleanup_lock(project, @desktop_lock, fn ->
      remove_temporary_markers(project.root, ".tmp-desktop-last-running-")
      desktop_root = Path.join([project.root, ".rekindle", "dev", "desktop"])
      desktop_selected = selected_desktop(project.root)

      desktop_root
      |> child_directories(project.root)
      |> Enum.each(fn directory ->
        target = Path.basename(directory)
        selected = if desktop_selected[:target] == target, do: desktop_selected[:generation]
        prune(project.root, directory, selected)
      end)
    end)

    :ok
  end

  defp cleanup_staging(project, target) do
    with_cleanup_lock(project, {:staging, target}, fn ->
      remove_owned_directory(
        project.root,
        Path.join([project.root, ".rekindle", "tmp", Atom.to_string(target)])
      )
    end)
  end

  defp with_cleanup_lock(project, key, function) do
    case Publication.with_lock(project.root, key, function) do
      {:error, {:publication_lock, reason}} ->
        Logger.warning("could not clean #{inspect(key)} state: #{inspect(reason)}")
        :ok

      result ->
        result
    end
  end

  @spec discard(Rekindle.Config.t(), Rekindle.Build.Result.t()) :: :ok
  def discard(project, %{target: :web, metadata: %{generation: generation, manifest: manifest}}) do
    with_cleanup_lock(project, {:web, :dev}, fn ->
      selected = selected_web(project.root)

      if selected != generation, do: remove_owned_directory(project.root, Path.dirname(manifest))
      web_locked(project, selected)
    end)
  end

  def discard(
        project,
        %{target: :desktop} = result
      ) do
    with_cleanup_lock(project, @desktop_lock, fn ->
      discard_desktop_locked(project.root, result)
    end)
  end

  def discard(_project, _result), do: :ok

  @spec web(Rekindle.Config.t(), String.t()) :: :ok
  def web(project, generation) do
    with_cleanup_lock(project, {:web, :dev}, fn -> web_locked(project, generation) end)
  end

  @doc false
  @spec web_locked(Rekindle.Config.t(), String.t() | nil) :: :ok
  def web_locked(project, generation) do
    prune(project.root, Path.join([project.root, ".rekindle", "dev", "web"]), generation)
  end

  @spec desktop(Path.t(), Rekindle.Build.Result.t()) :: :ok
  def desktop(root, result) do
    with_desktop_lock(root, fn ->
      marker = selected_desktop(root)
      selected = desktop_selection(marker, result.metadata.rust_target)
      desktop_locked(root, result, selected)
    end)
    |> cleanup_lock_result(@desktop_lock)
  end

  @doc false
  @spec with_desktop_lock(Path.t(), (-> result)) ::
          result | {:error, {:publication_lock, term()}}
        when result: term()
  def with_desktop_lock(root, function) when is_function(function, 0) do
    Publication.with_lock(root, @desktop_lock, function)
  end

  @doc false
  @spec desktop_locked(Path.t(), Rekindle.Build.Result.t(), String.t() | nil) :: :ok
  def desktop_locked(root, result, selected_generation) do
    directory =
      Path.join([
        root,
        ".rekindle",
        "dev",
        "desktop",
        result.metadata.rust_target
      ])

    prune(root, directory, selected_generation)
  end

  defp discard_desktop_locked(
         root,
         %{
           metadata: %{generation: generation, manifest: manifest, rust_target: target}
         } = result
       ) do
    marker = selected_desktop(root)
    selected = desktop_selection(marker, target)

    if selected != generation, do: remove_owned_directory(root, Path.dirname(manifest))
    desktop_locked(root, result, selected)
  end

  defp desktop_selection(marker, target) do
    if marker[:target] == target, do: marker[:generation]
  end

  defp cleanup_lock_result({:error, {:publication_lock, reason}}, key) do
    Logger.warning("could not clean #{inspect(key)} state: #{inspect(reason)}")
    :ok
  end

  defp cleanup_lock_result(result, _key), do: result

  defp prune(root, directory, selected) do
    case OwnedPath.validate_directory(root, directory) do
      :ok ->
        directory
        |> generations()
        |> Enum.sort_by(fn {_path, modified} -> modified end, :desc)
        |> keep(selected)
        |> Enum.each(&remove(root, &1))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        warn_unsafe(reason)
    end

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

  defp remove(root, path) do
    case OwnedPath.remove_directory(root, path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("could not remove #{path}: #{OwnedPath.format_error(reason)}")
    end
  end

  defp selected_web(root) do
    path = Path.join([root, ".rekindle", "dev", "web-current.json"])

    case OwnedPath.validate_parent(root, path) do
      :ok -> read_generation(path)
      {:error, _reason} -> nil
    end
  end

  defp selected_desktop(root) do
    path = Path.join([root, ".rekindle", "dev", "desktop-last-running.json"])

    case OwnedPath.validate_parent(root, path) do
      :ok -> read_desktop_generation(path)
      {:error, _reason} -> %{}
    end
  end

  defp read_desktop_generation(path) do
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

  defp child_directories(path, root) do
    case OwnedPath.validate_directory(root, path) do
      :ok -> real_child_directories(path)
      {:error, _reason} -> []
    end
  end

  defp real_child_directories(root) do
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

  defp remove_owned_directory(root, path) do
    case OwnedPath.remove_directory(root, path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not remove #{path}: #{OwnedPath.format_error(reason)}")
    end
  end

  defp remove_temporary_markers(root, prefix) do
    directory = Path.join([root, ".rekindle", "dev"])

    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.each(fn name ->
          path = Path.join(directory, name)
          OwnedPath.remove_file(root, path)
        end)

      {:error, _reason} ->
        :ok
    end
  end

  defp remove_empty_tmp_root(root) do
    path = Path.join([root, ".rekindle", "tmp"])

    with :ok <- OwnedPath.validate_directory(root, path) do
      case File.rmdir(path) do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    else
      {:error, _reason} -> :ok
    end
  end

  defp warn_unsafe(reason) do
    Logger.warning("could not inspect project state: #{OwnedPath.format_error(reason)}")
    :ok
  end
end
