defmodule Rekindle.Development.Cleanup do
  @moduledoc false

  @generation ~r/\A[0-9a-f]{32}\z/

  @spec startup(Rekindle.Config.t(), [:web | :desktop]) :: :ok
  def startup(project, targets) do
    if :web in targets do
      File.rm_rf(Path.join([project.root, ".rekindle", "tmp", "web"]))

      remove_temporary_files(Path.join([project.root, ".rekindle", "dev"]))
    end

    if :desktop in targets do
      File.rm_rf(Path.join([project.root, ".rekindle", "tmp", "desktop"]))
      File.rm_rf(Path.join([project.root, ".rekindle", "dev", "desktop"]))
    end

    :ok
  end

  @spec discard(Rekindle.Config.t(), Rekindle.Build.Result.t()) :: :ok
  def discard(project, %{target: :web, artifact: artifact, metadata: %{generation: generation}}) do
    directory = Path.dirname(artifact)
    root = Path.join([project.root, ".rekindle", "dev", "web"])

    if selected_web(project.root) != generation and inside?(directory, root),
      do: File.rm_rf(directory)

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
  def web(_project, _generation, _previous \\ nil), do: :ok

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
