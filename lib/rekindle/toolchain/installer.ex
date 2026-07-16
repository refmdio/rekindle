defmodule Rekindle.Toolchain.Installer do
  @moduledoc false

  alias Rekindle.Failure

  @executable "rekindle_toolchain"

  @spec ensure(map(), keyword()) :: {:ok, Path.t()} | {:error, Failure.t()}
  def ensure(asset, options) do
    cache_root = Keyword.fetch!(options, :cache_root)
    version = Keyword.fetch!(options, :rekindle_version)
    source_build? = Keyword.get(options, :source_build, false)
    offline? = Keyword.get(options, :offline, false)

    with :ok <- validate_asset(asset),
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

  defp acquire(:missing, destination, asset, source_build?, offline?, options) do
    cond do
      source_build? -> install_bytes(destination, asset, invoke!(options, :source_builder, asset))
      offline? -> {:error, :helper_missing, "verified helper is unavailable offline"}
      true -> install_bytes(destination, asset, invoke!(options, :fetcher, asset["url"]))
    end
  rescue
    error -> {:error, :helper_missing, Exception.message(error)}
  end

  defp acquire({:corrupt, path}, destination, asset, source_build?, offline?, options) do
    quarantine = path <> ".quarantine-" <> Integer.to_string(System.unique_integer([:positive]))
    File.rename(path, quarantine)
    acquire(:missing, destination, asset, source_build?, offline?, options)
  end

  defp install_bytes(destination, asset, bytes) when is_binary(bytes) do
    with :ok <- validate_bytes(bytes, asset) do
      File.mkdir_p!(Path.dirname(destination))
      temporary = destination <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
      File.write!(temporary, bytes, [:binary, :exclusive])
      File.chmod!(temporary, 0o700)

      case File.rename(temporary, destination) do
        :ok ->
          {:ok, destination}

        {:error, :eexist} ->
          File.rm(temporary)
          validate_cached(destination, asset)

        {:error, reason} ->
          File.rm(temporary)
          {:error, :io_failed, "helper installation failed: #{reason}"}
      end
    end
  end

  defp validate_cached(path, asset) do
    case File.read(path) do
      {:ok, bytes} ->
        with :ok <- validate_bytes(bytes, asset),
             {:ok, stat} <- File.stat(path),
             true <- stat.type == :regular and Bitwise.band(stat.mode, 0o100) != 0 do
          {:ok, path}
        else
          _ -> {:corrupt, path}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, :io_failed, "helper cache read failed: #{reason}"}
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

  defp validate_asset(asset) do
    required = ~w[os arch url size sha256]

    if is_map(asset) and Map.keys(asset) |> Enum.sort() == Enum.sort(required) and
         asset["url"] =~ ~r/\Ahttps:\/\// and is_integer(asset["size"]) and asset["size"] > 0 and
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

  defp failure(code, message) do
    stage =
      if code in [:helper_missing, :helper_checksum_mismatch, :unsupported_host],
        do: :compatibility,
        else: :execution

    Failure.new!(target: nil, stage: stage, code: code, message: message)
  end
end
