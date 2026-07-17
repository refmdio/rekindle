defmodule Rekindle.ArtifactStore.Filesystem do
  @moduledoc false

  import Bitwise

  alias Rekindle.{CanonicalValue, Failure}

  @chunk_size 1_048_576
  @state_write_kinds ~w[project_id attempt_marker seal_journal seal_metadata generation_reference rollback_pointer deletion_journal quarantine]a
  @state_temporary_pattern ~r/\A\.rekindle-state-v1-([a-z_]+)-([A-Za-z0-9_-]+)-([0-9a-f]{32})-([0-9a-f]{64})\.tmp\z/

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

  @spec atomic_write(Path.t(), map() | String.t(), atom(), keyword()) ::
          :ok | {:error, Failure.t()}
  def atomic_write(path, value, kind, options \\ [])

  def atomic_write(path, value, kind, options)
      when kind in @state_write_kinds and is_list(options) do
    bytes = if is_binary(value), do: value, else: CanonicalValue.encode!(value)
    parent = Path.dirname(path)

    with true <- valid_state_write_options?(options),
         transaction_id = Keyword.get(options, :transaction_id, random_id()),
         true <- is_binary(transaction_id),
         true <- Regex.match?(~r/\A[0-9a-f]{32}\z/, transaction_id) do
      temporary =
        Path.join(
          parent,
          state_temporary_name(kind, Path.basename(path), sha256_bytes(bytes), transaction_id)
        )

      case File.open(temporary, [:write, :binary, :exclusive]) do
        {:ok, io} -> run_owned_state_write(io, temporary, path, parent, bytes, kind, options)
        {:error, _reason} -> state_write_error()
      end
    else
      _ -> state_write_error()
    end
  end

  def atomic_write(_path, _value, _kind, _options), do: state_write_error()

  defp prepare_state_temporary(io, temporary, bytes, kind, options) do
    try do
      with :ok <- File.chmod(temporary, 0o600),
           :ok <- state_checkpoint(options, kind, :created),
           :ok <- IO.binwrite(io, bytes),
           :ok <- state_checkpoint(options, kind, :written),
           :ok <- :file.sync(io),
           :ok <- state_checkpoint(options, kind, :file_synced) do
        :ok
      end
    after
      File.close(io)
    end
  end

  defp run_owned_state_write(io, temporary, path, parent, bytes, kind, options) do
    result =
      try do
        with :ok <- prepare_state_temporary(io, temporary, bytes, kind, options),
             :ok <- File.rename(temporary, path),
             :ok <- state_checkpoint(options, kind, :renamed),
             :ok <- sync_directory(parent),
             :ok <- state_checkpoint(options, kind, :directory_synced) do
          :ok
        else
          {:error, %Failure{} = failure} -> {:error, failure}
          {:error, _reason} -> state_write_error()
          _other -> state_write_error()
        end
      rescue
        _exception -> state_write_error()
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  @spec state_temporary_name(atom(), String.t(), String.t(), String.t()) :: String.t()
  def state_temporary_name(kind, destination, digest, transaction_id \\ random_id())
      when kind in @state_write_kinds do
    encoded = Base.url_encode64(destination, padding: false)
    ".rekindle-state-v1-#{kind}-#{encoded}-#{transaction_id}-#{digest}.tmp"
  end

  @spec parse_state_temporary(String.t()) ::
          {:ok,
           %{
             kind: atom(),
             destination: String.t(),
             transaction_id: String.t(),
             digest: String.t()
           }}
          | :error
  def parse_state_temporary(name) do
    with [kind, encoded, transaction_id, digest] <-
           Regex.run(@state_temporary_pattern, name, capture: :all_but_first),
         kind = String.to_existing_atom(kind),
         true <- kind in @state_write_kinds,
         {:ok, destination} <- Base.url_decode64(encoded, padding: false),
         true <- safe_destination?(destination) do
      {:ok,
       %{
         kind: kind,
         destination: destination,
         transaction_id: transaction_id,
         digest: digest
       }}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @spec sha256_bytes(binary()) :: String.t()
  def sha256_bytes(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp state_checkpoint(options, kind, boundary) do
    case Keyword.get(options, :checkpoint) do
      nil -> :ok
      function when is_function(function, 1) -> function.({:artifact_state_write, kind, boundary})
      _ -> state_write_error()
    end
  end

  defp valid_state_write_options?(options),
    do:
      Keyword.keyword?(options) and Keyword.keys(options) -- [:checkpoint, :transaction_id] == []

  defp safe_destination?(destination),
    do:
      destination != "" and Path.basename(destination) == destination and
        not String.contains?(destination, ["/", "\\", <<0>>])

  defp state_write_error,
    do: error(:io_failed, "Artifact store record could not be published")

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
