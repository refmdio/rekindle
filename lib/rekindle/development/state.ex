defmodule Rekindle.Development.State do
  @moduledoc false

  alias Rekindle.Config
  alias Rekindle.Publication

  @spec put_error(Config.t(), String.t()) :: :ok
  def put_error(project, message) do
    path = error_path(project)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, temporary} <-
           Publication.temporary_file(Path.dirname(path), ".tmp-web-error-") do
      try do
        with :ok <- File.write(temporary, Jason.encode!(%{"error" => message})),
             :ok <- File.rename(temporary, path) do
          :ok
        else
          {:error, _reason} -> :ok
        end
      after
        File.rm(temporary)
      end
    else
      {:error, _reason} -> :ok
    end
  end

  @spec clear_error(Config.t()) :: :ok
  def clear_error(project) do
    case File.rm(error_path(project)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec build_error(Config.t()) :: {:ok, String.t()} | :none
  def build_error(project) do
    with {:ok, contents} <- File.read(error_path(project)),
         {:ok, %{"error" => message}} when is_binary(message) <- Jason.decode(contents) do
      {:ok, message}
    else
      _error -> :none
    end
  end

  defp error_path(project), do: Path.join([project.root, ".rekindle", "dev", "web-error.json"])
end
