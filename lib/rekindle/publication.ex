defmodule Rekindle.Publication do
  @moduledoc false

  @attempts 8
  @lock_timeout 120_000
  @poll_interval 10

  @spec temporary_directory(Path.t(), String.t()) ::
          {:ok, Path.t()} | {:error, File.posix()}
  def temporary_directory(parent, prefix \\ ".tmp-") do
    with :ok <- File.mkdir_p(parent) do
      reserve(parent, prefix, &File.mkdir/1, @attempts)
    end
  end

  @spec temporary_file(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def temporary_file(parent, prefix \\ ".tmp-") do
    with :ok <- File.mkdir_p(parent) do
      reserve(parent, prefix, &reserve_file/1, @attempts)
    end
  end

  @spec with_lock(Path.t(), term(), (-> result), timeout()) ::
          result | {:error, {:publication_lock, term()}}
        when result: term()
  def with_lock(root, key, function, timeout \\ @lock_timeout)
      when is_function(function, 0) and is_integer(timeout) and timeout >= 0 do
    name = lock_name(root, key)
    deadline = System.monotonic_time(:millisecond) + timeout
    acquire(name, deadline, function)
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

  defp reserve_file(path) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} -> File.close(file)
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire(name, deadline, function) do
    case :gen_tcp.listen(0, [
           :binary,
           active: false,
           ifaddr: {:local, name}
         ]) do
      {:ok, socket} ->
        try do
          function.()
        after
          :gen_tcp.close(socket)
        end

      {:error, :eaddrinuse} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_interval)
          acquire(name, deadline, function)
        else
          {:error, {:publication_lock, :timeout}}
        end

      {:error, reason} ->
        {:error, {:publication_lock, reason}}
    end
  end

  defp lock_name(root, key) do
    identity = :erlang.term_to_binary({Path.expand(root), key})
    digest = identity |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    <<0, "rekindle-", digest::binary>>
  end

  defp token do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
