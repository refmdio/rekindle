defmodule Rekindle.Publication do
  @moduledoc false

  @attempts 8

  @spec temporary_directory(Path.t(), String.t()) ::
          {:ok, Path.t()} | {:error, File.posix()}
  def temporary_directory(parent, prefix \\ ".tmp-") do
    reserve(parent, prefix, &File.mkdir/1)
  end

  @spec temporary_file(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def temporary_file(parent, prefix \\ ".tmp-") do
    reserve(parent, prefix, fn path ->
      case File.open(path, [:write, :binary, :exclusive]) do
        {:ok, file} -> File.close(file)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp reserve(parent, prefix, reserve) do
    case File.stat(parent) do
      {:ok, %{type: :directory}} -> reserve(parent, prefix, reserve, @attempts)
      {:ok, _stat} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve(_parent, _prefix, _reserve, 0), do: {:error, :eexist}

  defp reserve(parent, prefix, reserve, attempts) do
    path = Path.join(parent, prefix <> token())

    case reserve.(path) do
      :ok -> {:ok, path}
      {:error, :eexist} -> reserve(parent, prefix, reserve, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp token do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
