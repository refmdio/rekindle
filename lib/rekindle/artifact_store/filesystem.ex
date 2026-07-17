defmodule Rekindle.ArtifactStore.Filesystem do
  @moduledoc false

  import Bitwise

  alias Rekindle.{CanonicalValue, Failure}

  @chunk_size 1_048_576

  @spec ensure_private_directory(Path.t()) :: :ok | {:error, Failure.t()}
  def ensure_private_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when (mode &&& 0o777) == 0o700 ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        error(:path_invalid, "Artifact store directory permissions are unsafe")

      {:ok, _stat} ->
        error(:path_invalid, "Artifact store path is not a directory")

      {:error, :enoent} ->
        with :ok <- File.mkdir(path), :ok <- File.chmod(path, 0o700) do
          :ok
        else
          {:error, _reason} -> error(:io_failed, "Artifact store directory could not be created")
        end

      {:error, _reason} ->
        error(:io_failed, "Artifact store directory could not be inspected")
    end
  end

  @spec atomic_write(Path.t(), map() | String.t()) :: :ok | {:error, Failure.t()}
  def atomic_write(path, value) do
    bytes = if is_binary(value), do: value, else: CanonicalValue.encode!(value)
    parent = Path.dirname(path)
    temporary = Path.join(parent, ".#{Path.basename(path)}.#{random_id()}.tmp")

    with {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- IO.binwrite(io, bytes),
         :ok <- :file.sync(io),
         :ok <- File.close(io),
         :ok <- File.rename(temporary, path),
         :ok <- sync_directory(parent) do
      :ok
    else
      {:error, _reason} ->
        File.rm(temporary)
        error(:io_failed, "Artifact store record could not be published")

      other ->
        File.rm(temporary)
        error(:io_failed, "Artifact store record could not be published: #{inspect(other)}")
    end
  end

  @spec sync_file(Path.t()) :: :ok | {:error, Failure.t()}
  def sync_file(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]),
         :ok <- :file.sync(io),
         :ok <- File.close(io) do
      :ok
    else
      _ -> error(:io_failed, "Artifact file could not be synchronized")
    end
  end

  @spec sync_directory(Path.t()) :: :ok | {:error, Failure.t()}
  def sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, io} ->
        result = :file.sync(io)
        :ok = :file.close(io)

        case result do
          :ok -> :ok
          {:error, _reason} -> error(:io_failed, "Artifact directory sync is unsupported")
        end

      {:error, _reason} ->
        error(:io_failed, "Artifact directory sync is unsupported")
    end
  end

  @spec sha256(Path.t()) :: {:ok, String.t()} | {:error, Failure.t()}
  def sha256(path) do
    digest =
      path
      |> File.stream!(@chunk_size, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    _exception -> error(:io_failed, "Artifact member could not be hashed")
  end

  @spec remove_tree(Path.t()) :: :ok | {:error, Failure.t()}
  def remove_tree(path) do
    make_writable(path)

    case File.rm_rf(path) do
      {:ok, _paths} ->
        :ok

      {:error, _reason, _path} ->
        error(:cleanup_unconfirmed, "Owned staging could not be removed")
    end
  end

  defp make_writable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok = File.chmod(path, 0o700)

        case File.ls(path) do
          {:ok, names} -> Enum.each(names, &make_writable(Path.join(path, &1)))
          _ -> :ok
        end

      {:ok, %File.Stat{type: :regular}} ->
        :ok = File.chmod(path, 0o600)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @spec random_id() :: String.t()
  def random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp error(code, message) do
    {:error,
     Failure.new!(
       target: nil,
       stage: Failure.stage_for(code) |> elem(1),
       code: code,
       message: message
     )}
  end
end
