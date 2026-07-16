defmodule Rekindle.Toolchain.CompatibilityManifest do
  @moduledoc false

  alias Rekindle.{CanonicalValue, Failure}
  alias Rekindle.Toolchain.{Helper, Installer}

  defstruct [:rekindle_version, :helper_version, :assets, :digest]

  @type t :: %__MODULE__{
          rekindle_version: String.t(),
          helper_version: String.t(),
          assets: [map()],
          digest: String.t()
        }

  @spec load(keyword()) :: {:ok, t()} | {:error, Failure.t()}
  def load(options \\ []) do
    path = Keyword.get_lazy(options, :manifest_path, &default_path/0)

    with {:ok, bytes} <- File.read(path),
         {:ok, manifest} <- Jason.decode(bytes),
         true <- CanonicalValue.encode!(manifest) == bytes,
         :ok <- validate_manifest(manifest) do
      {:ok,
       %__MODULE__{
         rekindle_version: manifest["rekindle_version"],
         helper_version: manifest["helper"]["version"],
         assets: manifest["helper"]["assets"],
         digest: manifest["manifest_digest"]
       }}
    else
      _ -> {:error, failure(:helper_missing, "qualified compatibility manifest is unavailable")}
    end
  rescue
    _ -> {:error, failure(:helper_missing, "qualified compatibility manifest is unavailable")}
  end

  @spec host_asset(t()) :: {:ok, map()} | {:error, Failure.t()}
  def host_asset(%__MODULE__{} = release) do
    host = Installer.host()

    case Enum.find(release.assets, &(&1["os"] == host.os and &1["arch"] == host.arch)) do
      nil ->
        {:error, failure(:unsupported_host, "this host has no qualified helper asset")}

      asset ->
        {:ok, asset}
    end
  end

  @doc false
  @spec encode_helper_release!(map()) :: binary()
  def encode_helper_release!(attributes) do
    root = %{
      "contract_version" => 1,
      "rekindle_version" => Map.fetch!(attributes, "rekindle_version"),
      "helper" => Map.fetch!(attributes, "helper")
    }

    digest = domain_digest(root)
    CanonicalValue.encode!(Map.put(root, "manifest_digest", digest))
  end

  defp validate_manifest(manifest) do
    helper = manifest["helper"]
    without_digest = Map.delete(manifest, "manifest_digest")

    cond do
      Map.keys(manifest) |> Enum.sort() !=
          Enum.sort(~w[contract_version rekindle_version helper manifest_digest]) ->
        {:error, :shape}

      manifest["contract_version"] != 1 or not valid_version?(manifest["rekindle_version"]) ->
        {:error, :version}

      not is_map(helper) or
        Map.keys(helper) |> Enum.sort() != Enum.sort(~w[protocol version assets]) or
        helper["protocol"] != 1 or helper["version"] != Helper.compatibility()["helper_version"] ->
        {:error, :helper}

      not valid_assets?(helper["assets"]) ->
        {:error, :assets}

      manifest["manifest_digest"] != domain_digest(without_digest) ->
        {:error, :digest}

      true ->
        :ok
    end
  end

  defp valid_assets?(assets) when is_list(assets) and assets != [] do
    assets == Enum.sort_by(assets, &{&1["os"], &1["arch"]}) and
      length(assets) == MapSet.size(MapSet.new(assets, &{&1["os"], &1["arch"]})) and
      Enum.all?(assets, &valid_asset?/1)
  end

  defp valid_assets?(_assets), do: false

  defp valid_asset?(asset) do
    is_map(asset) and Map.keys(asset) |> Enum.sort() == Enum.sort(~w[os arch url size sha256]) and
      is_binary(asset["os"]) and is_binary(asset["arch"]) and
      is_binary(asset["url"]) and String.starts_with?(asset["url"], "https://") and
      is_integer(asset["size"]) and asset["size"] > 0 and
      is_binary(asset["sha256"]) and asset["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp valid_version?(value),
    do: is_binary(value) and value =~ ~r/\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/

  defp default_path do
    Application.get_env(
      :rekindle,
      :compatibility_manifest,
      Application.app_dir(:rekindle, "priv/rekindle-compatibility-v1.json")
    )
  end

  defp domain_digest(value),
    do:
      :crypto.hash(:sha256, ["rekindle-compatibility-v1\0", CanonicalValue.encode!(value)])
      |> Base.encode16(case: :lower)

  defp failure(code, message),
    do: Failure.new!(target: nil, stage: :compatibility, code: code, message: message)
end
