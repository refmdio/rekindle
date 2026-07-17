defmodule Rekindle.Toolchain.Installer do
  @moduledoc false

  alias Rekindle.Failure
  alias Rekindle.Toolchain.Executable

  @executable "rekindle_toolchain"

  @spec ensure(map(), keyword()) :: {:ok, Path.t()} | {:error, Failure.t()}
  def ensure(asset, options) do
    cache_root = Keyword.fetch!(options, :cache_root)
    version = Keyword.fetch!(options, :rekindle_version)
    source_build? = Keyword.get(options, :source_build, false)
    offline? = Keyword.get(options, :offline, false)

    with :ok <- validate_asset(asset, source_build?),
         :ok <- validate_host(asset),
         destination = destination(cache_root, version, asset),
         result <- validate_cached(destination, asset),
         {:ok, path} <- acquire(result, destination, asset, source_build?, offline?, options) do
      {:ok, path}
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      {:error, code, message} -> {:error, failure(code, message)}
    end
  end

  defp acquire({:ok, path}, _destination, _asset, _source?, _offline?, _options), do: {:ok, path}

  defp acquire(
         {:error, _code, _message} = error,
         _destination,
         _asset,
         _source?,
         _offline?,
         _options
       ),
       do: error

  defp acquire(:missing, destination, asset, source_build?, offline?, options) do
    cond do
      source_build? -> install_bytes(destination, asset, invoke!(options, :source_builder, asset))
      offline? -> {:error, :helper_missing, "verified helper is unavailable offline"}
      true -> install_download(destination, asset, options)
    end
  rescue
    error -> {:error, :helper_missing, Exception.message(error)}
  end

  defp acquire(
         {:corrupt, path, parent_stat},
         _destination,
         _asset,
         _source_build?,
         _offline?,
         _options
       ) do
    quarantine = path <> ".quarantine-" <> Integer.to_string(System.unique_integer([:positive]))

    case quarantine(path, quarantine, parent_stat) do
      :ok ->
        {:error, :helper_checksum_mismatch,
         "cached helper failed integrity or owner-only mode validation and was quarantined"}

      {:error, reason} ->
        {:error, :io_failed, "helper quarantine failed: #{reason}"}
    end
  end

  defp install_bytes(destination, asset, bytes) when is_binary(bytes) do
    with :ok <- validate_bytes(bytes, asset) do
      with_temporary(destination, fn temporary, io ->
        IO.binwrite(io, bytes)
        :ok = :file.sync(io)
        finalize_install(temporary, destination, asset)
      end)
    end
  end

  defp install_download(destination, asset, options) do
    with_temporary(destination, fn temporary, io ->
      with :ok <- invoke_fetcher(options, asset["url"], io, asset["size"], temporary),
           :ok <- :file.sync(io),
           :ok <- validate_file(temporary, asset) do
        finalize_install(temporary, destination, asset)
      end
    end)
  end

  defp with_temporary(destination, function) do
    parent = Path.dirname(destination)
    temporary = destination <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- Executable.ensure_private_directory(parent) do
      try do
        File.open!(temporary, [:write, :binary, :exclusive], fn io ->
          File.chmod!(temporary, 0o600)
          function.(temporary, io)
        end)
      after
        case File.lstat(temporary) do
          {:ok, _stat} -> File.rm(temporary)
          _ -> :ok
        end
      end
    else
      _ -> {:error, :io_failed, "helper cache directory is not a private no-follow path"}
    end
  end

  defp finalize_install(temporary, destination, asset) do
    File.chmod!(temporary, 0o700)

    File.open!(temporary, [:read, :binary], fn io ->
      :ok = :file.sync(io)
    end)

    case File.ln(temporary, destination) do
      :ok -> validate_cached(destination, asset)
      {:error, :eexist} -> validate_cached(destination, asset)
      {:error, reason} -> {:error, :io_failed, "helper installation failed: #{reason}"}
    end
  end

  defp validate_cached(path, asset) do
    case Executable.stat(path) do
      {:ok, _stat} ->
        case Executable.qualify(path,
               expected_sha256: asset["sha256"],
               expected_size: asset["size"],
               required_mode: 0o700
             ) do
          {:ok, _executable} -> {:ok, path}
          {:error, _reason} -> corrupt_entry(path)
        end

      {:error, :enoent} ->
        :missing

      {:error, :invalid_path} ->
        case Executable.first_unsafe_component(path) do
          {:ok, ^path} ->
            corrupt_entry(path)

          {:ok, _unsafe_ancestor} ->
            {:error, :io_failed, "helper cache path has an unsafe unowned ancestor"}

          {:error, reason} ->
            {:error, :io_failed, "helper cache path is unsafe: #{reason}"}
        end

      {:error, reason} ->
        {:error, :io_failed, "helper cache path qualification failed: #{reason}"}
    end
  end

  defp corrupt_entry(path) do
    case Executable.stat(Path.dirname(path)) do
      {:ok, %{type: :directory} = parent_stat} -> {:corrupt, path, parent_stat}
      _ -> {:error, :io_failed, "helper cache parent authority is unavailable"}
    end
  end

  defp validate_file(path, asset) do
    case Executable.qualify(path,
           executable: false,
           required_mode: 0o600,
           expected_size: asset["size"],
           expected_sha256: asset["sha256"]
         ) do
      {:ok, _file} ->
        :ok

      {:error, _reason} ->
        {:error, :helper_checksum_mismatch, "helper temporary file failed qualification"}
    end
  end

  defp validate_bytes(bytes, asset) do
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    cond do
      byte_size(bytes) != asset["size"] ->
        {:error, :helper_checksum_mismatch,
         "helper byte size does not match compatibility manifest"}

      digest != asset["sha256"] ->
        {:error, :helper_checksum_mismatch,
         "helper checksum does not match compatibility manifest"}

      true ->
        :ok
    end
  end

  defp quarantine(path, quarantine, expected_parent) do
    parent = Path.dirname(path)

    with {:ok, parent_before} <- Executable.stat(parent),
         true <- same_directory_node?(expected_parent, parent_before),
         {:ok, before_stat} <- File.lstat(path),
         :ok <- File.rename(path, quarantine),
         {:ok, after_stat} <- File.lstat(quarantine),
         true <- same_node?(before_stat, after_stat),
         {:ok, parent_after} <- Executable.stat(parent),
         true <- same_directory_node?(expected_parent, parent_after) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :identity_changed}
    end
  end

  defp same_node?(left, right) do
    fields = [:inode, :uid, :gid, :major_device, :minor_device, :size, :type, :mode]
    Map.take(left, fields) == Map.take(right, fields)
  end

  defp same_directory_node?(left, right) do
    fields = [:inode, :uid, :gid, :major_device, :minor_device, :type, :mode]
    Map.take(left, fields) == Map.take(right, fields)
  end

  defp validate_asset(asset, source_build?) do
    required = ~w[os arch url size sha256]

    valid_url? =
      if source_build?,
        do:
          is_nil(asset["url"]) or
            (is_binary(asset["url"]) and asset["url"] =~ ~r/\Ahttps:\/\//),
        else: is_binary(asset["url"]) and asset["url"] =~ ~r/\Ahttps:\/\//

    if is_map(asset) and Map.keys(asset) |> Enum.sort() == Enum.sort(required) and valid_url? and
         is_integer(asset["size"]) and asset["size"] > 0 and
         is_binary(asset["sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, asset["sha256"]) do
      :ok
    else
      {:error, :contract_violation, "invalid helper asset descriptor"}
    end
  end

  defp validate_host(asset) do
    host = host()

    if asset["os"] == host.os and asset["arch"] == host.arch,
      do: :ok,
      else: {:error, :unsupported_host, "helper asset does not match this host"}
  end

  @spec host() :: %{os: String.t(), arch: String.t()}
  def host do
    {family, name} = :os.type()
    os = if family == :unix and name == :darwin, do: "macos", else: Atom.to_string(name)

    arch =
      :erlang.system_info(:system_architecture) |> List.to_string() |> String.split("-") |> hd()

    %{os: os, arch: arch}
  end

  defp destination(root, version, asset) do
    Path.join([root, version, "#{asset["os"]}-#{asset["arch"]}", asset["sha256"], @executable])
  end

  defp invoke!(options, key, argument) do
    case Keyword.fetch(options, key) do
      {:ok, function} when is_function(function, 1) -> function.(argument)
      _ -> raise ArgumentError, "#{key} callback is required"
    end
  end

  defp invoke_fetcher(options, url, io, maximum, temporary) do
    case Keyword.fetch(options, :fetcher) do
      {:ok, function} when is_function(function, 4) ->
        function.(url, io, maximum, temporary)

      {:ok, function} when is_function(function, 3) ->
        function.(url, io, maximum)

      {:ok, function} when is_function(function, 1) ->
        bytes = function.(url)

        if is_binary(bytes) and byte_size(bytes) <= maximum do
          IO.binwrite(io, bytes)
          :ok
        else
          {:error, :helper_checksum_mismatch, "helper download exceeded its declared size"}
        end

      _ ->
        raise ArgumentError, "fetcher callback is required"
    end
  end

  defp failure(code, message) do
    stage =
      if code in [:helper_missing, :helper_checksum_mismatch, :unsupported_host],
        do: :compatibility,
        else: :execution

    Failure.new!(target: nil, stage: stage, code: code, message: message)
  end
end
