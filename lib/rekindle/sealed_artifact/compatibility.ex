defmodule Rekindle.SealedArtifact.Compatibility do
  @moduledoc false

  alias Rekindle.{CanonicalValue, Toolchain.Helper}

  @identity_keys ~w[v identity_digest id contract_version adapter generated_profile target capability]
  @adapter_keys ~w[crate version]
  @web_capability_keys ~w[support_level rust_target adapter_features dependencies host_descriptor graphics_requirement]
  @desktop_capability_keys ~w[support_level hosts adapter_features dependencies]
  @dependency_keys ~w[scope crate source default_features features]
  @spec helper_protocol?(term()) :: boolean()
  def helper_protocol?(value), do: value == Helper.compatibility()

  @spec tool_identity?(term(), String.t()) :: boolean()
  def tool_identity?(value, name) do
    exact?(value, ~w[name version content_digest]) and value["name"] == name and
      value["version"] == Helper.compatibility()["wasm_bindgen_schema"] and
      is_nil(value["content_digest"])
  end

  @spec integration_identity?(term(), Rekindle.target()) :: boolean()
  def integration_identity?(identity, target) do
    target_name = Atom.to_string(target)

    exact?(identity, @identity_keys) and identity["v"] == 2 and
      identity["contract_version"] == 1 and identity["target"] == target_name and
      valid_integration_header?(identity) and valid_capability?(identity["capability"], target) and
      identity["identity_digest"] == identity_digest(Map.delete(identity, "identity_digest"))
  rescue
    _ -> false
  end

  @spec host_requirements?(term(), Rekindle.target()) :: boolean()
  def host_requirements?(requirements, :web) do
    with true <-
           exact?(
             requirements,
             ~w[v target integration_identity host_descriptor graphics_requirement]
           ),
         true <- requirements["v"] == 1 and requirements["target"] == "web",
         true <- integration_identity?(requirements["integration_identity"], :web),
         capability <- requirements["integration_identity"]["capability"] do
      requirements["host_descriptor"] == capability["host_descriptor"] and
        requirements["graphics_requirement"] == capability["graphics_requirement"]
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def host_requirements?(requirements, :desktop) do
    exact?(requirements, ~w[v target integration_identity host_descriptor graphics_requirement]) and
      requirements["v"] == 1 and requirements["target"] == "desktop" and
      integration_identity?(requirements["integration_identity"], :desktop) and
      is_nil(requirements["host_descriptor"]) and is_nil(requirements["graphics_requirement"])
  rescue
    _ -> false
  end

  def host_requirements?(_requirements, _target), do: false

  defp valid_integration_header?(identity) do
    mapping = %{
      "gpui" => {"rekindle-gpui", "gpui-v1"},
      "egui" => {"rekindle-egui", "egui-v1"},
      "slint" => {"rekindle-slint", "slint-v1"}
    }

    case Map.get(mapping, identity["id"]) do
      {crate, profile} ->
        exact?(identity["adapter"], @adapter_keys) and
          identity["adapter"]["crate"] == crate and semver?(identity["adapter"]["version"]) and
          identity["generated_profile"] == profile

      nil ->
        false
    end
  end

  defp valid_capability?(capability, :web) do
    exact?(capability, @web_capability_keys) and
      capability["support_level"] in ~w[qualified experimental] and
      capability["rust_target"] == "wasm32-unknown-unknown" and
      strings?(capability["adapter_features"]) and dependencies?(capability["dependencies"]) and
      host_descriptor?(capability["host_descriptor"]) and
      graphics_requirement?(capability["graphics_requirement"])
  end

  defp valid_capability?(capability, :desktop) do
    exact?(capability, @desktop_capability_keys) and
      capability["support_level"] in ~w[qualified experimental] and
      capability["hosts"] == [
        %{"os" => "linux", "arch" => "x86_64"},
        %{"os" => "macos", "arch" => "aarch64"}
      ] and strings?(capability["adapter_features"]) and
      dependencies?(capability["dependencies"])
  end

  defp valid_capability?(_capability, _target), do: false

  defp dependencies?(dependencies) when is_list(dependencies) and dependencies != [] do
    dependencies == Enum.sort_by(dependencies, & &1["crate"]) and
      Enum.uniq_by(dependencies, & &1["crate"]) == dependencies and
      Enum.all?(dependencies, &dependency?/1)
  end

  defp dependencies?(_dependencies), do: false

  defp dependency?(dependency) do
    exact?(dependency, @dependency_keys) and dependency["scope"] in ~w[normal build] and
      safe_ascii?(dependency["crate"]) and is_boolean(dependency["default_features"]) and
      strings?(dependency["features"]) and source?(dependency["source"])
  end

  defp source?(%{"kind" => "git"} = source),
    do:
      exact?(source, ~w[kind url revision]) and https?(source["url"]) and
        is_binary(source["revision"]) and Regex.match?(~r/\A[0-9a-f]{40}\z/, source["revision"])

  defp source?(%{"kind" => "crates_io"} = source),
    do: exact?(source, ~w[kind version]) and semver?(source["version"])

  defp source?(_source), do: false

  defp host_descriptor?(%{"kind" => "body_owned"} = descriptor),
    do: exact?(descriptor, ~w[v kind]) and descriptor["v"] == 1

  defp host_descriptor?(%{"kind" => "mount_element"} = descriptor),
    do:
      exact?(descriptor, ~w[v kind element id]) and descriptor["v"] == 1 and
        descriptor["element"] == "canvas" and descriptor["id"] in ~w[rekindle-ui canvas]

  defp host_descriptor?(_descriptor), do: false

  defp graphics_requirement?(requirement) do
    exact?(requirement, ~w[v secure_context any_of]) and requirement["v"] == 2 and
      requirement["secure_context"] == true and alternatives?(requirement["any_of"])
  end

  defp alternatives?(alternatives) when is_list(alternatives) and alternatives != [] do
    order = %{"webgpu" => 0, "webgl2" => 1, "webgl1" => 2}
    apis = Enum.map(alternatives, & &1["api"])

    Enum.all?(alternatives, &alternative?/1) and Enum.uniq(apis) == apis and
      apis == Enum.sort_by(apis, &Map.fetch!(order, &1))
  rescue
    _ -> false
  end

  defp alternatives?(_alternatives), do: false

  defp alternative?(%{"api" => "webgpu"} = alternative) do
    exact?(alternative, ~w[api request adapter_validation]) and
      alternative["request"] == %{
        "power_preference" => "high-performance",
        "force_fallback_adapter" => false,
        "required_features" => %{
          "mode" => "if_adapter_supports",
          "names" => ["dual-source-blending"]
        },
        "required_limits" => %{
          "profile" => "downlevel-defaults",
          "resolution" => "adapter",
          "alignment" => "adapter"
        }
      } and
      exact?(alternative["adapter_validation"], ~w[owner profile]) and
      alternative["adapter_validation"]["owner"] == "integration_adapter" and
      safe_ascii?(alternative["adapter_validation"]["profile"])
  end

  defp alternative?(%{"api" => api} = alternative) when api in ~w[webgl2 webgl1],
    do: exact?(alternative, ~w[api])

  defp alternative?(_alternative), do: false

  defp strings?(values) when is_list(values),
    do: values == Enum.sort(Enum.uniq(values)) and Enum.all?(values, &safe_ascii?/1)

  defp strings?(_values), do: false

  defp identity_digest(identity) do
    :crypto.hash(
      :sha256,
      "rekindle-integration-identity-v2\0" <> CanonicalValue.encode!(identity)
    )
    |> Base.encode16(case: :lower)
  end

  defp exact?(value, keys),
    do: is_map(value) and Map.keys(value) |> Enum.sort() == Enum.sort(keys)

  defp semver?(value), do: is_binary(value) and match?({:ok, _}, Version.parse(value))
  defp https?(value), do: is_binary(value) and String.starts_with?(value, "https://")

  defp safe_ascii?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and
        Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E))
end
