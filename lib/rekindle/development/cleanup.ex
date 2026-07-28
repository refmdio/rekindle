defmodule Rekindle.Development.Cleanup do
  @moduledoc false

  @retained_web_generations 2
  @generation ~r/\A[0-9a-f]{32}\z/

  @spec startup(Rekindle.Config.t(), [:web | :desktop]) :: :ok
  def startup(project, targets) do
    if :web in targets do
      File.rm_rf(Path.join([project.root, ".rekindle", "tmp", "web"]))

      selected = selected_web(project.root)
      remove_temporary_files(Path.join([project.root, ".rekindle", "dev"]))
      prune_web(project.root, selected)
    end

    if :desktop in targets do
      File.rm_rf(Path.join([project.root, ".rekindle", "tmp", "desktop"]))
      File.rm_rf(Path.join([project.root, ".rekindle", "dev", "desktop"]))
    end

    :ok
  end

  @spec discard(Rekindle.Config.t(), Rekindle.Build.Result.t()) :: :ok
  def discard(project, %{target: :web, metadata: %{generation: generation, manifest: manifest}}) do
    if selected_web(project.root) != generation, do: File.rm_rf(Path.dirname(manifest))
    prune_web(project.root, selected_web(project.root))
    :ok
  end

  def discard(project, %{target: :desktop, metadata: %{manifest: manifest}}) do
    directory = Path.dirname(manifest)
    root = Path.join([project.root, ".rekindle", "dev", "desktop"])
    if inside?(directory, root), do: File.rm_rf(directory)
    :ok
  end

  def discard(_project, _result), do: :ok

  @spec web(Rekindle.Config.t(), String.t(), String.t() | nil) :: :ok
  def web(project, generation, previous \\ nil) do
    prune_web(project.root, [generation, previous])
    :ok
  end

  defp prune_web(root, selected) when not is_list(selected), do: prune_web(root, [selected])

  defp prune_web(root, selected) do
    directory = Path.join([root, ".rekindle", "dev", "web"])

    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@generation, &1))
        |> Enum.map(fn name ->
          path = Path.join(directory, name)

          case File.stat(path, time: :posix) do
            {:ok, %{type: :directory, mtime: modified}} -> {path, modified}
            _other -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> stale_generations(selected)
        |> Enum.each(&File.rm_rf/1)

      {:error, _reason} ->
        :ok
    end
  end

  defp stale_generations(generations, selected) do
    selected = selected |> Enum.reject(&is_nil/1) |> Enum.uniq()

    kept =
      selected
      |> Enum.flat_map(fn generation ->
        Enum.filter(generations, &(Path.basename(elem(&1, 0)) == generation))
      end)
      |> then(fn preferred ->
        recent =
          generations
          |> Enum.reject(&(&1 in preferred))
          |> Enum.take(max(@retained_web_generations - length(preferred), 0))

        preferred ++ recent
      end)
      |> MapSet.new(&elem(&1, 0))

    generations
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&MapSet.member?(kept, &1))
  end

  defp selected_web(root) do
    path = Path.join([root, ".rekindle", "dev", "web-current.json"])

    with {:ok, contents} <- File.read(path),
         {:ok, %{"generation" => generation}} <- Jason.decode(contents),
         true <- is_binary(generation) and Regex.match?(@generation, generation) do
      generation
    else
      _error -> nil
    end
  end

  defp remove_temporary_files(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, ".tmp-"))
        |> Enum.each(&File.rm_rf(Path.join(directory, &1)))

      {:error, _reason} ->
        :ok
    end
  end

  defp inside?(path, root) do
    expanded = Path.expand(path)
    expanded != root and String.starts_with?(expanded, root <> "/")
  end
end
