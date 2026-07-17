defmodule Rekindle.BuildGraph.Identity do
  @moduledoc false

  alias Rekindle.{BuildGraph, CanonicalValue, Failure}

  @node_domain "rekindle-node-v1\0"
  @model_slice_domain "rekindle-model-slice-v1\0"
  @config_domain "rekindle-node-config-v1\0"
  @environment_domain "rekindle-environment-v1\0"
  @value_domain "rekindle-value-v1\0"
  @secret_domain "rekindle-secret-value-v1\0"
  @output_domain "rekindle-node-output-v1\0"
  @metadata_domain "rekindle-node-metadata-v1\0"
  @project_model_domain "rekindle-project-model-v1\0"
  @external_plan_domain "rekindle-external-plan-v1\0"

  @tool_sets %{
    "cargo_web" => ~w[cargo rustc],
    "cargo_desktop" => ~w[cargo rustc],
    "external_web" => ~w[external_executable],
    "external_desktop" => ~w[external_executable],
    "bindgen_web" => ~w[rekindle_toolchain wasm-bindgen],
    "package_web" => ~w[bootstrap_template cargo gpui rekindle_toolchain rustc],
    "seal_web" => [],
    "seal_desktop" => :pipeline
  }

  defmodule Digest do
    @moduledoc false
    @enforce_keys [:digest, :preimage, :jcs, :value]
    defstruct @enforce_keys
  end

  defmodule NodeKey do
    @moduledoc false
    @enforce_keys [:key, :preimage, :input, :model_slice_digest, :config_digest]
    defstruct @enforce_keys
  end

  @spec digest(binary(), CanonicalValue.t()) :: {:ok, Digest.t()} | {:error, Failure.t()}
  def digest(domain, value) when is_binary(domain) and byte_size(domain) in 1..128 do
    with true <- String.ends_with?(domain, <<0>>),
         {:ok, jcs} <- CanonicalValue.encode(value) do
      preimage = domain <> jcs

      {:ok,
       %Digest{
         digest: sha256(preimage),
         preimage: preimage,
         jcs: jcs,
         value: value
       }}
    else
      _ -> invalid("Digest input is not canonical")
    end
  end

  def digest(_domain, _value), do: invalid("Digest domain is invalid")

  @spec value_digest(CanonicalValue.t(), boolean()) :: {:ok, Digest.t()} | {:error, Failure.t()}
  def value_digest(value, secret? \\ false)
  def value_digest(value, false), do: digest(@value_domain, value)
  def value_digest(value, true), do: digest(@secret_domain, value)
  def value_digest(_value, _secret), do: invalid("Value digest secrecy is invalid")

  @spec external_plan(Rekindle.ExternalPlan.t(), map()) ::
          {:ok, Digest.t()} | {:error, Failure.t()}
  def external_plan(%Rekindle.ExternalPlan{contract_version: 1} = plan, executable) do
    with true <- valid_external_executable?(executable),
         true <- string_list?(plan.argv),
         true <- plan.env_mode == :replace,
         {:ok, env_set} <- external_environment(plan.env_set),
         true <- valid_external_cwd?(plan.cwd),
         true <- plan.diagnostic_mode in [:opaque, :cargo_json],
         true <- is_integer(plan.timeout_ms) and plan.timeout_ms > 0,
         true <- relative_path?(plan.expected_manifest) do
      value = %{
        "v" => 1,
        "executable" => stringify(executable),
        "argv" => plan.argv,
        "cwd" => %{
          "root" => plan.cwd.root |> Atom.to_string(),
          "path" => plan.cwd.path
        },
        "env_mode" => "replace",
        "env_set" => env_set,
        "diagnostic_mode" => Atom.to_string(plan.diagnostic_mode),
        "timeout_ms" => plan.timeout_ms,
        "expected_manifest" => plan.expected_manifest
      }

      digest(@external_plan_domain, value)
    else
      {:error, _} = error -> error
      _ -> invalid("External plan identity is invalid")
    end
  end

  def external_plan(_plan, _executable), do: invalid("External plan identity is invalid")

  @spec environment(:none | :toolchain | :host, [map()]) ::
          {:ok, Digest.t()} | {:error, Failure.t()}
  def environment(inherit, entries)
      when inherit in [:none, :toolchain, :host] and is_list(entries) do
    with {:ok, entries} <- environment_entries(entries),
         value = %{
           "v" => 1,
           "inherit" => Atom.to_string(inherit),
           "entries" => entries
         },
         {:ok, result} <- digest(@environment_domain, value) do
      {:ok, result}
    end
  end

  def environment(_inherit, _entries), do: invalid("Environment identity is invalid")

  @spec portable_package(Path.t(), map()) :: {:ok, map()} | {:error, Failure.t()}
  def portable_package(project_root, package) when is_binary(project_root) and is_map(package) do
    manifest_path = Map.get(package, :manifest_path)
    name = Map.get(package, :name)
    version = Map.get(package, :version)

    with true <- normalized_absolute?(project_root),
         true <- normalized_absolute?(manifest_path),
         true <- descendant?(manifest_path, project_root),
         relative <- Path.relative_to(manifest_path, project_root),
         true <- relative_path?(relative),
         true <- safe_identifier?(name),
         true <- safe_identifier?(version) do
      {:ok,
       %{
         "kind" => "local",
         "manifest_path" => relative,
         "name" => name,
         "version" => version
       }}
    else
      _ -> failure(:path_invalid, "Local Cargo package escapes the project root")
    end
  end

  def portable_package(_project_root, _package),
    do: invalid("Portable package identity is invalid")

  @spec model_slice(map()) :: {:ok, Digest.t()} | {:error, Failure.t()}
  def model_slice(value) when is_map(value) do
    if valid_model_slice?(value),
      do: digest(@model_slice_domain, value),
      else: invalid("Model slice does not match its closed schema")
  end

  def model_slice(_value), do: invalid("Model slice is invalid")

  @spec config_identity(map()) :: {:ok, Digest.t()} | {:error, Failure.t()}
  def config_identity(value) when is_map(value) do
    if valid_config?(value),
      do: digest(@config_domain, value),
      else: invalid("Node configuration does not match its closed schema")
  end

  def config_identity(_value), do: invalid("Node configuration identity is invalid")

  @spec node_key(keyword()) :: {:ok, NodeKey.t()} | {:error, Failure.t()}
  def node_key(options) when is_list(options) do
    node = Keyword.get(options, :node)
    target = Keyword.get(options, :target)
    profile = Keyword.get(options, :profile)
    model_slice = Keyword.get(options, :model_slice)
    config = Keyword.get(options, :config)
    direct_inputs = Keyword.get(options, :direct_inputs, [])
    predecessors = Keyword.get(options, :predecessors, [])
    tools = Keyword.get(options, :tools, [])

    with true <- node in BuildGraph.keyed_nodes(),
         true <- target in [:web, :desktop],
         true <- node_target?(node, target),
         true <- safe_identifier?(profile),
         {:ok, model} <- model_slice(model_slice),
         {:ok, config} <- config_identity(config),
         {:ok, direct_inputs} <- direct_inputs(direct_inputs),
         {:ok, predecessors} <- predecessors(predecessors),
         {:ok, tools} <- tools(node, config.value, tools),
         input = %{
           "v" => 1,
           "node" => Atom.to_string(node),
           "target" => Atom.to_string(target),
           "profile" => profile,
           "model_slice_digest" => model.digest,
           "config_digest" => config.digest,
           "direct_inputs" => direct_inputs,
           "predecessors" => predecessors,
           "tools" => tools
         },
         {:ok, result} <- digest(@node_domain, input) do
      {:ok,
       %NodeKey{
         key: result.digest,
         preimage: result.preimage,
         input: input,
         model_slice_digest: model.digest,
         config_digest: config.digest
       }}
    else
      {:error, _} = error -> error
      _ -> invalid("Node key input is invalid")
    end
  end

  def node_key(_options), do: invalid("Node key input is invalid")

  @spec output_digest(map(), map()) :: {:ok, Digest.t()} | {:error, Failure.t()}
  def output_digest(descriptor, metadata) when is_map(descriptor) and is_map(metadata) do
    with true <- valid_metadata?(metadata),
         {:ok, metadata_digest} <- digest(@metadata_domain, metadata),
         true <- valid_output?(descriptor, metadata_digest.digest),
         {:ok, output} <- digest(@output_domain, descriptor) do
      {:ok, output}
    else
      {:error, _} = error -> error
      _ -> invalid("Node output descriptor is invalid")
    end
  end

  def output_digest(_descriptor, _metadata), do: invalid("Node output descriptor is invalid")

  @spec project_model_digest(map()) :: {:ok, Digest.t()} | {:error, Failure.t()}
  def project_model_digest(model) when is_map(model) do
    if exact_keys?(
         model,
         ~w[v application_id client targets local_packages cargo_inputs compatibility_tuple_id]
       ) and
         model["v"] == 1 and safe_identifier?(model["application_id"]) and
         relative_path?(model["client"]) and valid_target_models?(model["targets"]) and
         valid_local_packages?(model["local_packages"]) and
         valid_cargo_inputs?(model["cargo_inputs"]) and sha256?(model["compatibility_tuple_id"]) do
      digest(@project_model_domain, model)
    else
      invalid("Project model identity is invalid")
    end
  end

  def project_model_digest(_model), do: invalid("Project model identity is invalid")

  defp environment_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      name = fetch(entry, :name)
      source = fetch(entry, :source)
      value = fetch(entry, :value)
      secret = fetch(entry, :secret)

      with true <- env_name?(name),
           true <- source in [:inherited, :literal, :host],
           true <- is_binary(value),
           true <- is_boolean(secret),
           {:ok, value_digest} <- value_digest(value, secret) do
        normalized = %{
          "name" => name,
          "source" => Atom.to_string(source),
          "value_digest" => value_digest.digest,
          "secret" => secret
        }

        {:cont, {:ok, [normalized | acc]}}
      else
        _ -> {:halt, invalid("Environment entry is invalid")}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.sort_by(normalized, & &1["name"])

        if unique_by?(normalized, & &1["name"]),
          do: {:ok, normalized},
          else: invalid("Environment names must be unique")

      error ->
        error
    end
  end

  defp external_environment(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      name = fetch(entry, :name)
      value = fetch(entry, :value)
      secret = fetch(entry, :secret)

      with true <- env_name?(name),
           true <- is_binary(value),
           true <- is_boolean(secret),
           {:ok, identity} <- value_digest(value, secret) do
        normalized = %{
          "name" => name,
          "value_digest" => identity.digest,
          "secret" => secret
        }

        {:cont, {:ok, [normalized | acc]}}
      else
        _ -> {:halt, invalid("External environment entry is invalid")}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.sort_by(normalized, & &1["name"])

        if unique_by?(normalized, & &1["name"]),
          do: {:ok, normalized},
          else: invalid("External environment names must be unique")

      error ->
        error
    end
  end

  defp external_environment(_entries), do: invalid("External environment is invalid")

  defp direct_inputs(inputs) when is_list(inputs) do
    if Enum.all?(inputs, &valid_direct_input?/1) do
      sorted = Enum.sort_by(inputs, &direct_input_key/1)

      if unique_by?(sorted, &direct_input_key/1),
        do: {:ok, sorted},
        else: invalid("Direct inputs contain duplicates")
    else
      invalid("Direct input is invalid")
    end
  end

  defp direct_inputs(_inputs), do: invalid("Direct inputs are invalid")

  defp predecessors(items) when is_list(items) do
    if Enum.all?(items, &valid_predecessor?/1) do
      sorted =
        Enum.sort_by(items, fn item ->
          elem(BuildGraph.order(String.to_existing_atom(item["node"])), 1)
        end)

      if unique_by?(sorted, & &1["node"]),
        do: {:ok, sorted},
        else: invalid("Predecessors contain duplicates")
    else
      invalid("Predecessor is invalid")
    end
  rescue
    _ -> invalid("Predecessor is invalid")
  end

  defp predecessors(_items), do: invalid("Predecessors are invalid")

  defp tools(node, config, items) when is_list(items) do
    node_name = Atom.to_string(node)
    expected = expected_tools(node_name, config)
    items = Enum.map(items, &normalize_tool/1)

    if Enum.all?(items, &valid_tool?/1) do
      sorted = Enum.sort_by(items, & &1["name"])
      names = Enum.map(sorted, & &1["name"])

      if names == expected and unique_by?(sorted, & &1["name"]),
        do: {:ok, sorted},
        else: invalid("Node tool set is incomplete or contains additional tools")
    else
      invalid("Tool identity is invalid")
    end
  end

  defp tools(_node, _config, _items), do: invalid("Tool identities are invalid")

  defp normalize_tool(%{"version" => version} = tool) when is_binary(version) do
    normalized =
      version
      |> String.replace("\r\n", "\n")
      |> remove_one_trailing_lf()

    %{tool | "version" => normalized}
  end

  defp normalize_tool(tool), do: tool

  defp remove_one_trailing_lf(value) do
    if String.ends_with?(value, "\n"),
      do: binary_part(value, 0, byte_size(value) - 1),
      else: value
  end

  defp expected_tools("seal_desktop", config) do
    case get_in(config, ["fields", "pipeline"]) do
      "canonical" -> ~w[cargo gpui rekindle_toolchain rustc]
      "extension" -> []
      _ -> ["<invalid>"]
    end
  end

  defp expected_tools(node, _config), do: Map.fetch!(@tool_sets, node)

  defp valid_model_slice?(%{"v" => 1, "node" => node, "target" => target} = value) do
    case node do
      node when node in ~w[cargo_web cargo_desktop] ->
        exact_keys?(
          value,
          ~w[v node target package_identity binary local_package_identities has_local_build_script cargo_input_paths source_roots]
        ) and
          target_for_node?(node, target) and portable_package?(value["package_identity"]) and
          sorted_unique?(value["local_package_identities"], &CanonicalValue.encode!/1) and
          Enum.all?(value["local_package_identities"], &portable_package?/1) and
          is_boolean(value["has_local_build_script"]) and safe_identifier?(value["binary"]) and
          sorted_relative_paths?(value["cargo_input_paths"]) and
          sorted_relative_paths?(value["source_roots"])

      node when node in ~w[external_web external_desktop] ->
        exact_keys?(
          value,
          ~w[v node target application_id rekindle_version client package binary profile features public_root hot_styles runtime_manifest]
        ) and
          target_for_node?(node, target) and safe_identifier?(value["application_id"]) and
          safe_identifier?(value["rekindle_version"]) and relative_path?(value["client"]) and
          Enum.all?(~w[package binary profile], &safe_identifier?(value[&1])) and
          sorted_identifiers?(value["features"]) and optional_relative?(value["public_root"]) and
          sorted_relative_paths?(value["hot_styles"]) and
          runtime_manifest?(value["runtime_manifest"], target)

      node when node in ~w[bindgen_web package_web seal_web seal_desktop] ->
        exact_keys?(value, ~w[v node target]) and target_for_node?(node, target)

      _ ->
        false
    end
  end

  defp valid_model_slice?(_value), do: false

  defp valid_target_models?(targets) when is_list(targets) do
    targets != [] and Enum.all?(targets, &valid_target_model?/1) and
      targets == Enum.sort_by(Enum.uniq_by(targets, & &1["target"]), &target_rank(&1["target"]))
  end

  defp valid_target_models?(_targets), do: false

  defp valid_target_model?(%{"kind" => "canonical"} = target) do
    exact_keys?(
      target,
      ~w[kind target package_identity package binary rust_target profile features default_features toolchain_identity environment_digest public_root hot_styles runtime projection]
    ) and target["target"] in ~w[web desktop] and portable_package?(target["package_identity"]) and
      Enum.all?(~w[package binary rust_target profile], &safe_identifier?(target[&1])) and
      sorted_identifiers?(target["features"]) and is_boolean(target["default_features"]) and
      toolchain_identity?(target["toolchain_identity"]) and sha256?(target["environment_digest"]) and
      target_common?(target)
  end

  defp valid_target_model?(%{"kind" => "extension"} = target) do
    exact_keys?(
      target,
      ~w[kind target package binary profile features backend_id backend_version options_digest public_root hot_styles runtime projection]
    ) and target["target"] in ~w[web desktop] and
      Enum.all?(
        ~w[package binary profile backend_id backend_version],
        &safe_identifier?(target[&1])
      ) and
      sorted_identifiers?(target["features"]) and sha256?(target["options_digest"]) and
      target_common?(target)
  end

  defp valid_target_model?(_target), do: false

  defp target_common?(%{"target" => "web"} = target) do
    optional_relative?(target["public_root"]) and sorted_relative_paths?(target["hot_styles"]) and
      is_nil(target["runtime"]) and
      target["projection"] == %{
        "mode" => "phoenix_static",
        "root" => target["projection"]["root"]
      } and
      relative_path?(target["projection"]["root"])
  end

  defp target_common?(%{"target" => "desktop"} = target) do
    is_nil(target["public_root"]) and target["hot_styles"] == [] and
      desktop_runtime?(target["runtime"]) and
      target["projection"] == %{"mode" => "directory", "root" => target["projection"]["root"]} and
      relative_path?(target["projection"]["root"])
  end

  defp desktop_runtime?(runtime) when is_map(runtime) do
    exact_keys?(
      runtime,
      ~w[readiness startup_timeout_ms startup_grace_ms shutdown_timeout_ms replacement handoff]
    ) and
      runtime["readiness"] in ~w[ipc_v1 startup_grace] and uint?(runtime["startup_timeout_ms"]) and
      (is_nil(runtime["startup_grace_ms"]) or uint?(runtime["startup_grace_ms"])) and
      uint?(runtime["shutdown_timeout_ms"]) and
      runtime["replacement"] in ~w[overlap replace_before_start] and
      runtime["handoff"] in ~w[enabled disabled]
  end

  defp desktop_runtime?(_runtime), do: false

  defp valid_local_packages?(packages) when is_list(packages) do
    Enum.all?(packages, fn package ->
      exact_keys?(
        package,
        ~w[package_identity name version manifest_path source_roots custom_build]
      ) and
        portable_package?(package["package_identity"]) and safe_identifier?(package["name"]) and
        safe_identifier?(package["version"]) and relative_path?(package["manifest_path"]) and
        sorted_relative_paths?(package["source_roots"]) and is_boolean(package["custom_build"])
    end) and sorted_unique?(packages, &CanonicalValue.encode!(&1["package_identity"]))
  end

  defp valid_local_packages?(_packages), do: false

  defp valid_cargo_inputs?(inputs) when is_list(inputs) do
    Enum.all?(inputs, fn input ->
      exact_keys?(input, ~w[path sha256 size]) and relative_path?(input["path"]) and
        sha256?(input["sha256"]) and uint?(input["size"])
    end) and sorted_unique?(inputs, & &1["path"])
  end

  defp valid_cargo_inputs?(_inputs), do: false

  defp target_rank("web"), do: 0
  defp target_rank("desktop"), do: 1
  defp target_rank(_target), do: 2

  defp valid_config?(%{"v" => 1, "node" => node, "target" => target, "fields" => fields} = value)
       when is_map(fields) do
    exact_keys?(value, ~w[v node target fields]) and target_for_node?(node, target) and
      valid_config_fields?(node, fields)
  end

  defp valid_config?(_value), do: false

  defp valid_config_fields?(node, fields) when node in ~w[cargo_web cargo_desktop] do
    exact_keys?(
      fields,
      ~w[package_identity binary rust_target profile features default_features toolchain environment_digest]
    ) and
      portable_package?(fields["package_identity"]) and
      Enum.all?(~w[binary rust_target profile], &safe_identifier?(fields[&1])) and
      sorted_identifiers?(fields["features"]) and is_boolean(fields["default_features"]) and
      toolchain_identity?(fields["toolchain"]) and sha256?(fields["environment_digest"])
  end

  defp valid_config_fields?("bindgen_web", fields) do
    exact_keys?(
      fields,
      ~w[wasm_bindgen_schema wasm_bindgen_version source_maps debug helper_protocol helper_version]
    ) and
      Enum.all?(
        ~w[wasm_bindgen_schema wasm_bindgen_version helper_version],
        &safe_identifier?(fields[&1])
      ) and
      fields["source_maps"] in ~w[disabled external] and is_boolean(fields["debug"]) and
      uint?(fields["helper_protocol"])
  end

  defp valid_config_fields?("package_web", fields) do
    exact_keys?(
      fields,
      ~w[application_id rekindle_version compatibility_tuple_id gpui_revision public_root hot_styles bootstrap_template_digest web_manifest_schema max_files max_input_bytes max_output_bytes]
    ) and
      Enum.all?(~w[application_id rekindle_version gpui_revision], &safe_identifier?(fields[&1])) and
      sha256?(fields["compatibility_tuple_id"]) and optional_relative?(fields["public_root"]) and
      sorted_relative_paths?(fields["hot_styles"]) and
      sha256?(fields["bootstrap_template_digest"]) and
      fields["web_manifest_schema"] == 1 and
      Enum.all?(~w[max_files max_input_bytes max_output_bytes], &uint?(fields[&1]))
  end

  defp valid_config_fields?("seal_web", fields) do
    exact_keys?(
      fields,
      ~w[artifact_schema seal_policy max_generation_bytes max_manifest_bytes max_members]
    ) and
      fields["artifact_schema"] == 1 and fields["seal_policy"] == 1 and
      Enum.all?(~w[max_generation_bytes max_manifest_bytes max_members], &uint?(fields[&1]))
  end

  defp valid_config_fields?("seal_desktop", %{"pipeline" => "canonical"} = fields) do
    exact_keys?(
      fields,
      ~w[pipeline application_id rekindle_version compatibility_tuple_id gpui_revision helper_protocol helper_version runtime_manifest artifact_schema seal_policy max_generation_bytes]
    ) and
      desktop_seal_common?(fields) and sha256?(fields["compatibility_tuple_id"]) and
      safe_identifier?(fields["gpui_revision"]) and uint?(fields["helper_protocol"]) and
      safe_identifier?(fields["helper_version"])
  end

  defp valid_config_fields?("seal_desktop", %{"pipeline" => "extension"} = fields) do
    exact_keys?(
      fields,
      ~w[pipeline application_id rekindle_version backend_id backend_version options_digest runtime_manifest artifact_schema seal_policy max_generation_bytes]
    ) and
      desktop_seal_common?(fields) and
      Enum.all?(~w[backend_id backend_version], &safe_identifier?(fields[&1])) and
      sha256?(fields["options_digest"])
  end

  defp valid_config_fields?(node, fields) when node in ~w[external_web external_desktop] do
    exact_keys?(fields, ~w[backend_id backend_version options_digest external_plan_digest]) and
      Enum.all?(~w[backend_id backend_version], &safe_identifier?(fields[&1])) and
      sha256?(fields["options_digest"]) and sha256?(fields["external_plan_digest"])
  end

  defp valid_config_fields?(_node, _fields), do: false

  defp desktop_seal_common?(fields) do
    Enum.all?(~w[application_id rekindle_version], &safe_identifier?(fields[&1])) and
      runtime_manifest?(fields["runtime_manifest"], "desktop") and fields["artifact_schema"] == 1 and
      fields["seal_policy"] == 1 and uint?(fields["max_generation_bytes"])
  end

  defp valid_direct_input?(
         %{
           "kind" => "file",
           "path" => path,
           "file_kind" => kind,
           "sha256" => digest,
           "size" => size
         } = input
       ),
       do:
         exact_keys?(input, ~w[kind path file_kind sha256 size]) and relative_path?(path) and
           kind in ~w[data executable] and sha256?(digest) and uint?(size)

  defp valid_direct_input?(%{"kind" => "empty_directory", "path" => path} = input),
    do: exact_keys?(input, ~w[kind path]) and relative_path?(path)

  defp valid_direct_input?(
         %{"kind" => "value", "name" => name, "value_digest" => digest} = input
       ),
       do:
         exact_keys?(input, ~w[kind name value_digest]) and safe_identifier?(name) and
           sha256?(digest)

  defp valid_direct_input?(_input), do: false

  defp direct_input_key(%{"kind" => "value", "name" => name}), do: {"value", name}
  defp direct_input_key(%{"kind" => kind, "path" => path}), do: {kind, path}

  defp valid_predecessor?(%{"node" => node, "node_key" => key, "output_digest" => output} = item) do
    exact_keys?(item, ~w[node node_key output_digest]) and
      node in Enum.map(BuildGraph.keyed_nodes(), &Atom.to_string/1) and
      sha256?(key) and sha256?(output)
  end

  defp valid_predecessor?(_item), do: false

  defp valid_tool?(%{"name" => name, "version" => version, "content_digest" => content} = item) do
    exact_keys?(item, ~w[name version content_digest]) and safe_identifier?(name) and
      normalized_version?(version) and (is_nil(content) or sha256?(content)) and
      content_requirement?(name, content)
  end

  defp valid_tool?(_item), do: false

  defp content_requirement?(name, content)
       when name in ~w[rekindle_toolchain bootstrap_template external_executable],
       do: sha256?(content)

  defp content_requirement?(name, nil) when name in ~w[cargo rustc gpui wasm-bindgen], do: true
  defp content_requirement?(_name, _content), do: false

  defp valid_metadata?(%{"v" => 1, "node" => node} = metadata)
       when node in ~w[cargo_web cargo_desktop] do
    exact_keys?(metadata, ~w[v node artifact_kind package_identity binary rust_target profile]) and
      metadata["artifact_kind"] == if(node == "cargo_web", do: "wasm", else: "executable") and
      portable_package?(metadata["package_identity"]) and
      Enum.all?(~w[binary rust_target profile], &safe_identifier?(metadata[&1]))
  end

  defp valid_metadata?(%{"v" => 1, "node" => node} = metadata)
       when node in ~w[external_web external_desktop] do
    exact_keys?(metadata, ~w[v node producer expected_manifest]) and
      valid_producer?(metadata["producer"]) and relative_path?(metadata["expected_manifest"])
  end

  defp valid_metadata?(%{"v" => 1, "node" => "bindgen_web"} = metadata) do
    exact_keys?(metadata, ~w[v node entry_js wasm source_maps]) and
      relative_path?(metadata["entry_js"]) and relative_path?(metadata["wasm"]) and
      sorted_relative_paths?(metadata["source_maps"])
  end

  defp valid_metadata?(%{"v" => 1, "node" => "package_web"} = metadata) do
    exact_keys?(metadata, ~w[v node artifact_id manifest_digest entry producer]) and
      sha256?(metadata["artifact_id"]) and sha256?(metadata["manifest_digest"]) and
      relative_path?(metadata["entry"]) and valid_producer?(metadata["producer"])
  end

  defp valid_metadata?(%{"v" => 1, "node" => node} = metadata)
       when node in ~w[seal_web seal_desktop] do
    exact_keys?(metadata, ~w[v node artifact_id manifest_digest sealed_schema]) and
      sha256?(metadata["artifact_id"]) and sha256?(metadata["manifest_digest"]) and
      metadata["sealed_schema"] == 1
  end

  defp valid_metadata?(_metadata), do: false

  defp valid_output?(
         %{"v" => 1, "node" => node, "files" => files, "metadata_digest" => digest} = descriptor,
         expected
       )
       when is_list(files) do
    exact_keys?(descriptor, ~w[v node files metadata_digest]) and
      node in Enum.map(BuildGraph.keyed_nodes(), &Atom.to_string/1) and
      digest == expected and sorted_unique?(files, & &1["path"]) and
      Enum.all?(files, &valid_output_file?(&1, node))
  end

  defp valid_output?(_descriptor, _expected), do: false

  defp valid_producer?(
         %{
           "kind" => "canonical",
           "compatibility_tuple_id" => tuple,
           "gpui_revision" => gpui,
           "helper_version" => helper
         } = producer
       ) do
    exact_keys?(producer, ~w[kind compatibility_tuple_id gpui_revision helper_version]) and
      sha256?(tuple) and safe_identifier?(gpui) and safe_identifier?(helper)
  end

  defp valid_producer?(
         %{
           "kind" => "extension",
           "backend_id" => id,
           "backend_version" => version,
           "options_digest" => options
         } = producer
       ) do
    exact_keys?(producer, ~w[kind backend_id backend_version options_digest]) and
      safe_identifier?(id) and safe_identifier?(version) and sha256?(options)
  end

  defp valid_producer?(_producer), do: false

  defp valid_output_file?(
         %{"path" => path, "sha256" => digest, "size" => size, "mode" => mode} = file,
         node
       ) do
    exact_keys?(file, ~w[path sha256 size mode]) and relative_path?(path) and sha256?(digest) and
      uint?(size) and
      mode in ~w[data executable] and
      (mode == "data" or node in ~w[cargo_desktop external_desktop seal_desktop])
  end

  defp toolchain_identity?(%{"kind" => "rustup"} = value) do
    exact_keys?(value, ~w[kind name cargo_version rustc_vv rust_target components]) and
      safe_identifier?(value["name"]) and normalized_version?(value["cargo_version"]) and
      normalized_version?(value["rustc_vv"]) and safe_identifier?(value["rust_target"]) and
      sorted_identifiers?(value["components"])
  end

  defp toolchain_identity?(%{"kind" => "path"} = value) do
    exact_keys?(
      value,
      ~w[kind declared_identity cargo_sha256 rustc_sha256 cargo_version rustc_vv rust_target]
    ) and
      safe_identifier?(value["declared_identity"]) and sha256?(value["cargo_sha256"]) and
      sha256?(value["rustc_sha256"]) and normalized_version?(value["cargo_version"]) and
      normalized_version?(value["rustc_vv"]) and safe_identifier?(value["rust_target"])
  end

  defp toolchain_identity?(_value), do: false

  defp valid_external_executable?(value) when is_map(value) do
    value = stringify(value)

    exact_keys?(value, ~w[path_digest content_sha256 size]) and
      sha256?(value["path_digest"]) and sha256?(value["content_sha256"]) and
      uint?(value["size"])
  end

  defp valid_external_executable?(_value), do: false

  defp valid_external_cwd?(%{root: root, path: path}),
    do: root in [:project, :client, :staging] and (path == "." or relative_path?(path))

  defp valid_external_cwd?(_cwd), do: false

  defp portable_package?(
         %{"kind" => "local", "manifest_path" => path, "name" => name, "version" => version} =
           value
       ),
       do:
         exact_keys?(value, ~w[kind manifest_path name version]) and relative_path?(path) and
           safe_identifier?(name) and safe_identifier?(version)

  defp portable_package?(_value), do: false

  defp runtime_manifest?(nil, "web"), do: true
  defp runtime_manifest?(nil, :web), do: true

  defp runtime_manifest?(%{"readiness" => readiness, "handoff" => handoff} = value, target)
       when target in ["desktop", :desktop],
       do:
         exact_keys?(value, ~w[readiness handoff]) and readiness in ~w[ipc_v1 startup_grace] and
           handoff in ~w[ipc_v1 disabled]

  defp runtime_manifest?(_value, _target), do: false

  defp target_for_node?(node, target),
    do: target_for_node?(node, target, String.ends_with?(node, "_web"))

  defp target_for_node?(_node, "web", true), do: true
  defp target_for_node?(_node, "desktop", false), do: true
  defp target_for_node?(_node, _target, _web), do: false

  defp node_target?(node, target),
    do: target_for_node?(Atom.to_string(node), Atom.to_string(target))

  defp sorted_relative_paths?(values),
    do: sorted_unique?(values, & &1) and Enum.all?(values, &relative_path?/1)

  defp sorted_identifiers?(values),
    do: sorted_unique?(values, & &1) and Enum.all?(values, &safe_identifier?/1)

  defp optional_relative?(nil), do: true
  defp optional_relative?(value), do: relative_path?(value)

  defp sorted_unique?(values, mapper) when is_list(values),
    do: values == Enum.sort_by(Enum.uniq_by(values, mapper), mapper)

  defp sorted_unique?(_values, _mapper), do: false

  defp unique_by?(values, mapper),
    do: length(values) == values |> Enum.uniq_by(mapper) |> length()

  defp exact_keys?(map, keys), do: is_map(map) and Map.keys(map) |> Enum.sort() == Enum.sort(keys)
  defp fetch(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp stringify(map),
    do:
      Map.new(map, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)

  defp string_list?(values), do: is_list(values) and Enum.all?(values, &safe_text?/1)

  defp relative_path?(value) when is_binary(value) do
    segments = String.split(value, "/")

    byte_size(value) in 1..4_096 and String.valid?(value) and
      String.normalize(value, :nfc) == value and
      Path.type(value) == :relative and not String.contains?(value, ["\\", <<0>>]) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/, value) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp relative_path?(_value), do: false

  defp descendant?(path, root),
    do:
      (
        relative = Path.relative_to(path, root)
        relative != path and relative != ".." and not String.starts_with?(relative, "../")
      )

  defp normalized_absolute?(value),
    do: is_binary(value) and Path.type(value) == :absolute and Path.expand(value) == value

  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp uint?(value), do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991

  defp safe_identifier?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x1F\x7F]/, value)

  defp safe_text?(value),
    do:
      is_binary(value) and byte_size(value) <= 8_192 and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x1F\x7F]/, value)

  defp env_name?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/, value)

  defp normalized_version?(value) do
    safe_identifier?(value) or
      (is_binary(value) and byte_size(value) in 1..8_192 and String.valid?(value) and
         not String.contains?(value, [<<0>>, "\r"]) and not String.ends_with?(value, "\n\n"))
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp invalid(message), do: failure(:contract_violation, message)

  defp failure(code, message) do
    {:error,
     Failure.new!(
       target: nil,
       stage: elem(Failure.stage_for(code), 1),
       code: code,
       message: message
     )}
  end
end
