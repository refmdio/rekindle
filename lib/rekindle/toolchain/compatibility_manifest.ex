defmodule Rekindle.Toolchain.CompatibilityManifest do
  @moduledoc false

  alias Rekindle.{CanonicalValue, Failure}
  alias Rekindle.Toolchain.{Helper, Installer}

  defstruct [:rekindle_version, :helper_version, :assets, :digest, :root]

  @root_keys ~w[contract_version rekindle_version elixir otp phoenix endpoint_adapters igniter targets helper client_template tuples evidence manifest_digest]
  @range_keys ~w[min max_exclusive tested]
  @tuple_keys ~w[v tuple_id rekindle_version elixir otp phoenix igniter endpoint_adapter target host rust wasm_bindgen gpui browser helper client_template]
  @sha ~r/\A[0-9a-f]{64}\z/

  @type t :: %__MODULE__{
          rekindle_version: String.t(),
          helper_version: String.t(),
          assets: [map()],
          digest: String.t(),
          root: map()
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
         digest: manifest["manifest_digest"],
         root: manifest
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
      nil -> {:error, failure(:unsupported_host, "this host has no qualified helper asset")}
      asset -> {:ok, asset}
    end
  end

  @doc false
  @spec encode_release!(map()) :: binary()
  def encode_release!(root) when is_map(root) do
    root = Map.delete(root, "manifest_digest")
    CanonicalValue.encode!(Map.put(root, "manifest_digest", manifest_digest(root)))
  end

  @doc false
  @spec tuple_id(map()) :: String.t()
  def tuple_id(tuple) when is_map(tuple) do
    domain_digest("rekindle-compatibility-tuple-v1\0", Map.delete(tuple, "tuple_id"))
  end

  defp validate_manifest(manifest) do
    without_digest = Map.delete(manifest, "manifest_digest")
    helper = manifest["helper"]
    targets = manifest["targets"]
    tuples = manifest["tuples"]
    evidence = manifest["evidence"]

    with :ok <- exact_keys(manifest, @root_keys),
         true <- manifest["contract_version"] == 1,
         true <- valid_version?(manifest["rekindle_version"]),
         true <- Enum.all?(~w[elixir otp phoenix igniter], &valid_range?(manifest[&1])),
         true <- valid_adapters?(manifest["endpoint_adapters"]),
         true <- valid_targets?(targets),
         true <- valid_helper?(helper),
         true <- valid_client_template?(manifest["client_template"]),
         true <- valid_tuples?(tuples, manifest),
         true <- valid_evidence?(evidence, tuples),
         true <- coverage_complete?(manifest),
         true <- manifest["manifest_digest"] == manifest_digest(without_digest) do
      :ok
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  defp valid_range?(range) do
    exact_keys?(range, @range_keys) and valid_version?(range["min"]) and
      valid_version?(range["max_exclusive"]) and version_lt?(range["min"], range["max_exclusive"]) and
      sorted_versions?(range["tested"]) and
      Enum.all?(range["tested"], fn version ->
        not version_lt?(version, range["min"]) and version_lt?(version, range["max_exclusive"])
      end)
  end

  defp valid_adapters?(adapters) when is_list(adapters) and adapters != [] do
    Enum.all?(adapters, fn adapter ->
      exact_keys?(adapter, ["name" | @range_keys]) and valid_identifier?(adapter["name"]) and
        valid_range?(Map.take(adapter, @range_keys))
    end) and adapters == Enum.sort_by(adapters, & &1["name"]) and
      unique_by?(adapters, & &1["name"])
  end

  defp valid_adapters?(_), do: false

  defp valid_targets?(%{"web" => web, "desktop" => desktop} = targets) do
    exact_keys?(targets, ~w[web desktop]) and
      exact_keys?(
        web,
        ~w[rust_toolchain rust_components rust_targets wasm_bindgen gpui_source gpui_revision browsers secure_context webgpu]
      ) and
      valid_identifier?(web["rust_toolchain"]) and sorted_strings?(web["rust_components"], false) and
      sorted_strings?(web["rust_targets"], false) and valid_version?(web["wasm_bindgen"]) and
      valid_text?(web["gpui_source"]) and valid_revision?(web["gpui_revision"]) and
      valid_browsers?(web["browsers"]) and web["secure_context"] == true and web["webgpu"] == true and
      exact_keys?(desktop, ~w[rust_toolchain gpui_source gpui_revision hosts]) and
      valid_identifier?(desktop["rust_toolchain"]) and valid_text?(desktop["gpui_source"]) and
      valid_revision?(desktop["gpui_revision"]) and valid_hosts?(desktop["hosts"])
  end

  defp valid_targets?(_), do: false

  defp valid_browsers?(browsers) when is_list(browsers) and browsers != [] do
    Enum.all?(browsers, fn value ->
      exact_keys?(value, ~w[family version]) and valid_identifier?(value["family"]) and
        valid_version?(value["version"])
    end) and browsers == Enum.sort_by(browsers, &{&1["family"], &1["version"]}) and
      unique_by?(browsers, &{&1["family"], &1["version"]})
  end

  defp valid_browsers?(_), do: false

  defp valid_hosts?(hosts) when is_list(hosts) and hosts != [] do
    Enum.all?(hosts, &valid_host?/1) and hosts == Enum.sort_by(hosts, &{&1["os"], &1["arch"]}) and
      unique_by?(hosts, &{&1["os"], &1["arch"]})
  end

  defp valid_hosts?(_), do: false

  defp valid_host?(host),
    do:
      exact_keys?(host, ~w[os arch]) and valid_identifier?(host["os"]) and
        valid_identifier?(host["arch"])

  defp valid_helper?(helper) do
    exact_keys?(helper, ~w[protocol version assets]) and helper["protocol"] == 1 and
      helper["version"] == Helper.compatibility()["helper_version"] and
      valid_assets?(helper["assets"])
  end

  defp valid_assets?(assets) when is_list(assets) and assets != [] do
    Enum.all?(assets, &valid_asset?/1) and assets == Enum.sort_by(assets, &{&1["os"], &1["arch"]}) and
      unique_by?(assets, &{&1["os"], &1["arch"]})
  end

  defp valid_assets?(_), do: false

  defp valid_asset?(asset) do
    exact_keys?(asset, ~w[os arch url size sha256]) and valid_identifier?(asset["os"]) and
      valid_identifier?(asset["arch"]) and is_binary(asset["url"]) and
      String.starts_with?(asset["url"], "https://") and is_integer(asset["size"]) and
      asset["size"] > 0 and sha256?(asset["sha256"])
  end

  defp valid_client_template?(template) do
    exact_keys?(template, ~w[version rekindle_client manifest_sha256]) and
      valid_version?(template["version"]) and valid_version?(template["rekindle_client"]) and
      sha256?(template["manifest_sha256"])
  end

  defp valid_tuples?(tuples, manifest) when is_list(tuples) and tuples != [] do
    Enum.all?(tuples, &valid_tuple?(&1, manifest)) and
      tuples == Enum.sort_by(tuples, & &1["tuple_id"]) and
      unique_by?(tuples, & &1["tuple_id"])
  end

  defp valid_tuples?(_, _), do: false

  defp valid_tuple?(tuple, manifest) do
    exact_keys?(tuple, @tuple_keys) and tuple["v"] == 1 and
      tuple["tuple_id"] == tuple_id(tuple) and
      tuple["rekindle_version"] == manifest["rekindle_version"] and
      Enum.all?(~w[elixir otp phoenix igniter], fn key ->
        tuple[key] in manifest[key]["tested"]
      end) and valid_tuple_target?(tuple, manifest) and valid_host?(tuple["host"]) and
      valid_rust?(tuple["rust"]) and valid_gpui?(tuple["gpui"], manifest) and
      valid_tuple_helper?(tuple["helper"], manifest["helper"]) and
      tuple_asset_matches_host?(tuple, manifest["helper"]) and
      tuple["client_template"] ==
        Map.take(manifest["client_template"], ~w[version manifest_sha256])
  end

  defp valid_tuple_target?(%{"target" => "web"} = tuple, manifest) do
    adapter = tuple["endpoint_adapter"]
    browser = tuple["browser"]

    is_map(adapter) and exact_keys?(adapter, ~w[name version]) and
      Enum.any?(manifest["endpoint_adapters"], fn declared ->
        declared["name"] == adapter["name"] and adapter["version"] in declared["tested"]
      end) and tuple["wasm_bindgen"] == manifest["targets"]["web"]["wasm_bindgen"] and
      valid_tuple_browser?(browser, manifest["targets"]["web"]) and
      tuple["rust"] == %{
        "toolchain" => manifest["targets"]["web"]["rust_toolchain"],
        "components" => manifest["targets"]["web"]["rust_components"],
        "targets" => manifest["targets"]["web"]["rust_targets"]
      } and target_gpui?(tuple, manifest["targets"]["web"])
  end

  defp valid_tuple_target?(%{"target" => "desktop"} = tuple, manifest) do
    is_nil(tuple["endpoint_adapter"]) and is_nil(tuple["wasm_bindgen"]) and
      is_nil(tuple["browser"]) and
      tuple["host"] in manifest["targets"]["desktop"]["hosts"] and
      tuple["rust"] == %{
        "toolchain" => manifest["targets"]["desktop"]["rust_toolchain"],
        "components" => [],
        "targets" => []
      } and target_gpui?(tuple, manifest["targets"]["desktop"])
  end

  defp valid_tuple_target?(_, _), do: false

  defp valid_tuple_browser?(browser, web) do
    exact_keys?(browser, ~w[family version secure_context webgpu]) and
      Map.take(browser, ~w[family version]) in web["browsers"] and
      browser["secure_context"] == web["secure_context"] and browser["webgpu"] == web["webgpu"]
  end

  defp valid_rust?(rust) do
    exact_keys?(rust, ~w[toolchain components targets]) and valid_identifier?(rust["toolchain"]) and
      sorted_strings?(rust["components"], true) and sorted_strings?(rust["targets"], true)
  end

  defp valid_gpui?(gpui, manifest) do
    exact_keys?(gpui, ~w[source revision]) and
      Enum.any?(Map.values(manifest["targets"]), fn target ->
        gpui == %{"source" => target["gpui_source"], "revision" => target["gpui_revision"]}
      end)
  end

  defp valid_tuple_helper?(helper, declared) do
    exact_keys?(helper, ~w[protocol version asset_sha256]) and
      helper["protocol"] == declared["protocol"] and
      helper["version"] == declared["version"] and
      Enum.any?(declared["assets"], &(&1["sha256"] == helper["asset_sha256"]))
  end

  defp tuple_asset_matches_host?(tuple, helper) do
    Enum.any?(helper["assets"], fn asset ->
      tuple["host"] == Map.take(asset, ~w[os arch]) and
        tuple["helper"]["asset_sha256"] == asset["sha256"]
    end)
  end

  defp target_gpui?(tuple, target) do
    tuple["gpui"] == %{
      "source" => target["gpui_source"],
      "revision" => target["gpui_revision"]
    }
  end

  defp valid_evidence?(evidence, tuples) when is_list(evidence) and evidence != [] do
    ids = MapSet.new(tuples, & &1["tuple_id"])

    Enum.all?(evidence, fn row ->
      exact_keys?(row, ~w[tuple_id ci_job source_revision]) and row["tuple_id"] in ids and
        valid_text?(row["ci_job"]) and valid_revision?(row["source_revision"])
    end) and evidence == Enum.sort_by(evidence, &{&1["tuple_id"], &1["ci_job"]}) and
      unique_by?(evidence, &{&1["tuple_id"], &1["ci_job"]}) and
      Enum.all?(ids, fn id -> Enum.any?(evidence, &(&1["tuple_id"] == id)) end)
  end

  defp valid_evidence?(_, _), do: false

  defp coverage_complete?(manifest) do
    tuples = manifest["tuples"]

    Enum.all?(~w[elixir otp phoenix igniter], fn key ->
      Enum.all?(manifest[key]["tested"], fn version ->
        Enum.any?(tuples, &(&1[key] == version))
      end)
    end) and
      Enum.all?(manifest["endpoint_adapters"], fn adapter ->
        Enum.all?(adapter["tested"], fn version ->
          Enum.any?(tuples, fn tuple ->
            tuple["endpoint_adapter"] == %{"name" => adapter["name"], "version" => version}
          end)
        end)
      end) and
      Enum.all?(manifest["helper"]["assets"], fn asset ->
        Enum.any?(tuples, fn tuple ->
          tuple["host"] == Map.take(asset, ~w[os arch]) and
            tuple["helper"]["asset_sha256"] == asset["sha256"]
        end)
      end) and
      Enum.all?(manifest["targets"]["desktop"]["hosts"], fn host ->
        Enum.any?(tuples, &(&1["target"] == "desktop" and &1["host"] == host))
      end) and
      Enum.all?(manifest["targets"]["web"]["browsers"], fn browser ->
        Enum.any?(tuples, fn tuple ->
          tuple["target"] == "web" and
            Map.take(tuple["browser"], ~w[family version]) == browser
        end)
      end)
  end

  defp sorted_versions?(versions) when is_list(versions) and versions != [] do
    Enum.all?(versions, &valid_version?/1) and versions == Enum.sort(versions, &version_before?/2) and
      Enum.uniq(versions) == versions
  end

  defp sorted_versions?(_), do: false

  defp version_before?(left, right) do
    case Version.compare(left, right) do
      :lt -> true
      :gt -> false
      :eq -> :lists.sort([left, right]) == [left, right]
    end
  end

  defp version_lt?(left, right), do: Version.compare(left, right) == :lt

  defp sorted_strings?(values, allow_empty?) when is_list(values) do
    (allow_empty? or values != []) and Enum.all?(values, &valid_text?/1) and
      values == Enum.sort(values) and Enum.uniq(values) == values
  end

  defp sorted_strings?(_, _), do: false

  defp unique_by?(values, function),
    do: length(values) == values |> Enum.uniq_by(function) |> length()

  defp exact_keys?(value, keys),
    do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_keys(value, keys), do: if(exact_keys?(value, keys), do: :ok, else: {:error, :keys})
  defp sha256?(value), do: is_binary(value) and Regex.match?(@sha, value)
  defp valid_revision?(value), do: is_binary(value) and value =~ ~r/\A[0-9a-f]{40,64}\z/
  defp valid_version?(value), do: is_binary(value) and match?({:ok, _}, Version.parse(value))

  defp valid_identifier?(value),
    do: is_binary(value) and value =~ ~r/\A[A-Za-z0-9][A-Za-z0-9_.+-]{0,127}\z/

  defp valid_text?(value),
    do:
      is_binary(value) and value != "" and byte_size(value) <= 4_096 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp default_path do
    Application.get_env(
      :rekindle,
      :compatibility_manifest,
      Application.app_dir(:rekindle, "priv/rekindle-compatibility-v1.json")
    )
  end

  defp manifest_digest(value), do: domain_digest("rekindle-compatibility-v1\0", value)

  defp domain_digest(domain, value),
    do:
      :crypto.hash(:sha256, [domain, CanonicalValue.encode!(value)])
      |> Base.encode16(case: :lower)

  defp failure(code, message),
    do: Failure.new!(target: nil, stage: :compatibility, code: code, message: message)
end
