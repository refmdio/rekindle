defmodule Rekindle.Development.State do
  @moduledoc false

  alias Rekindle.Config
  alias Rekindle.Publication

  @entry "app.js"
  @generation ~r/\A[0-9a-f]{32}\z/
  @subscriptions Rekindle.Development.Subscriptions

  @spec put_error(Config.t(), String.t()) :: :ok
  def put_error(project, message) do
    path = error_path(project)

    result =
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

    notify(project)
    result
  end

  @spec clear_error(Config.t()) :: :ok
  def clear_error(project) do
    result =
      case File.rm(error_path(project)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> :ok
      end

    notify(project)
    result
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

  @spec web_status(Config.t()) :: map()
  def web_status(project) do
    case build_error(project) do
      {:ok, message} ->
        %{"type" => "build_failed", "error" => message}

      :none ->
        case current_generation(project) do
          {:ok, generation} ->
            %{
              "type" => "current_generation",
              "generation" => generation,
              "entry" => "/@rekindle/web/#{generation}/#{@entry}"
            }

          :none ->
            %{"type" => "pending"}
        end
    end
  end

  defp current_generation(project) do
    selector_path = Path.join([project.root, ".rekindle", "dev", "web-current.json"])

    with {:ok, contents} <- File.read(selector_path),
         {:ok, %{"generation" => generation}} <- Jason.decode(contents),
         true <- Regex.match?(@generation, generation),
         true <-
           File.regular?(Path.join([project.root, ".rekindle", "dev", "web", generation, @entry])) do
      {:ok, generation}
    else
      _error -> :none
    end
  end

  defp notify(project) do
    if Process.whereis(@subscriptions) do
      Registry.dispatch(@subscriptions, project.root, fn subscriptions ->
        for {pid, _value} <- subscriptions, do: send(pid, {__MODULE__, :changed})
      end)
    end

    :ok
  end

  defp error_path(project), do: Path.join([project.root, ".rekindle", "dev", "web-error.json"])
end
