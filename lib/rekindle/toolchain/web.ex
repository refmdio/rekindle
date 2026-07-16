defmodule Rekindle.Toolchain.Web do
  @moduledoc false

  alias Rekindle.CanonicalValue

  @root_keys ~w[id path mode device]
  @file_keys ~w[root_id path sha256 size mode]
  @limit_keys ~w[max_files max_input_bytes max_output_bytes deadline_ms]
  @ops ~w[bindgen_web package_web verify_web]
  @error_codes ~w[invalid_request incompatible_schema input_changed invalid_wasm bindgen_failed unsupported_import asset_escape asset_collision output_limit io_failed internal]
  @marker ".rekindle-attempt"
  @manifest "rekindle-web-manifest-v1.json"
  @max_manifest_string_bytes 4_096
  @max_path_bytes 4_096
  @application_id_pattern ~r/\A[a-z][a-z0-9_-]{0,127}\z/
  @backend_id_pattern ~r/\A[a-z][a-z0-9_.-]{0,127}\z/
  @gpui_revision_pattern ~r/\A[0-9a-f]{40,64}\z/
  @bootstrap_template """
  export async function start(context) {
    if (!context || context.v !== 1) throw new Error("invalid Rekindle context");
    const styles = __REKINDLE_HOT_STYLES__;
    await Promise.all(styles.map((href) => new Promise((resolve, reject) => {
      const link = Object.assign(document.createElement("link"), { rel: "stylesheet", href });
      link.onload = resolve;
      link.onerror = reject;
      document.head.appendChild(link);
    })));
    const module = await import(__REKINDLE_ENTRY__);
    const wasm = new URL(__REKINDLE_WASM__, import.meta.url);
    await module.default(wasm);
  }
  """

  defstruct request_id: nil, op: nil, progress_sequence: 0, terminal?: false

  @type t :: %__MODULE__{
          request_id: String.t() | nil,
          op: String.t() | nil,
          progress_sequence: non_neg_integer(),
          terminal?: boolean()
        }

  @spec root(Path.t(), :read | :write_empty, keyword()) :: {:ok, map()} | {:error, atom()}
  def root(path, mode, options \\ []) when mode in [:read, :write_empty] do
    path = Path.expand(path)
    id = Keyword.get_lazy(options, :id, &random_id/0)

    with :ok <- request_id(id),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         :ok <- validate_empty(path, mode, id, stat) do
      {:ok,
       %{
         "id" => id,
         "path" => path,
         "mode" => Atom.to_string(mode),
         "device" => stat.major_device * 4_294_967_296 + stat.minor_device
       }}
    else
      _ -> {:error, :invalid_root}
    end
  end

  @spec prepare_output_root(Path.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def prepare_output_root(path, options \\ []) do
    path = Path.expand(path)
    id = Keyword.get_lazy(options, :id, &random_id/0)
    marker = Path.join(path, @marker)

    with :ok <- request_id(id),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         :ok <- create_marker(marker, marker_bytes(id)),
         {:ok, root} <- root(path, :write_empty, id: id) do
      {:ok, root}
    else
      _ -> {:error, :invalid_root}
    end
  end

  @spec file(map(), String.t(), :data | :executable) :: {:ok, map()} | {:error, atom()}
  def file(root, relative, mode \\ :data) when mode in [:data, :executable] do
    with :ok <- validate_root(root),
         :ok <- relative_path(relative),
         path = Path.expand(relative, root["path"]),
         true <- contained?(path, root["path"]),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         {:ok, bytes} <- File.read(path),
         true <- mode == :data or Bitwise.band(stat.mode, 0o100) != 0 do
      {:ok,
       %{
         "root_id" => root["id"],
         "path" => relative,
         "sha256" => sha256(bytes),
         "size" => byte_size(bytes),
         "mode" => Atom.to_string(mode)
       }}
    else
      _ -> {:error, :invalid_file}
    end
  end

  @spec limits(keyword()) :: {:ok, map()} | {:error, atom()}
  def limits(options) do
    limits = %{
      "max_files" => Keyword.get(options, :max_files),
      "max_input_bytes" => Keyword.get(options, :max_input_bytes),
      "max_output_bytes" => Keyword.get(options, :max_output_bytes),
      "deadline_ms" => Keyword.get(options, :deadline_ms)
    }

    if Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
      do: {:ok, limits},
      else: {:error, :invalid_limits}
  end

  @spec operation(String.t(), map(), keyword()) :: {:ok, map(), t()} | {:error, atom()}
  def operation(op, body, options \\ [])

  def operation(op, body, options) when op in @ops and is_map(body) do
    request_id = Keyword.get_lazy(options, :request_id, &random_id/0)

    with :ok <- request_id(request_id),
         :ok <- validate_operation(op, stringify(body)) do
      header =
        body
        |> stringify()
        |> Map.merge(%{
          "v" => 1,
          "type" => "operation",
          "request_id" => request_id,
          "payload_len" => 0,
          "op" => op
        })

      {:ok, header, %__MODULE__{request_id: request_id, op: op}}
    end
  end

  def operation(_op, _body, _options), do: {:error, :invalid_operation}

  @spec accept(t(), map()) :: {:ok, t(), map()} | {:terminal, map(), t()} | {:error, atom()}
  def accept(%__MODULE__{terminal?: true}, _header), do: {:error, :post_terminal_frame}

  def accept(state, header) do
    cond do
      header["request_id"] != state.request_id or header["v"] != 1 or header["payload_len"] != 0 ->
        {:error, :invalid_web_frame}

      header["type"] == "operation_progress" ->
        progress(state, header)

      header["type"] == "operation_ok" ->
        terminal_ok(state, header)

      header["type"] == "operation_error" ->
        terminal_error(state, header)

      true ->
        {:error, :unexpected_web_frame}
    end
  end

  @spec revalidate_files(map(), [map()], keyword()) :: :ok | {:error, atom()}
  def revalidate_files(root, files, options \\ []) do
    allow_marker? = Keyword.get(options, :allow_marker, true)

    with :ok <- validate_root(root),
         true <- root["mode"] == "write_empty",
         true <- files == Enum.sort_by(files, & &1["path"]),
         true <- unique?(Enum.map(files, & &1["path"])),
         :ok <- validate_descriptors(root, files),
         {:ok, actual} <- actual_files(root["path"], allow_marker?),
         true <- actual == Enum.map(files, & &1["path"]) do
      :ok
    else
      _ -> {:error, :output_changed}
    end
  end

  @spec marker() :: String.t()
  def marker, do: @marker

  @spec bootstrap_template() :: map()
  def bootstrap_template do
    %{"id" => "v1", "sha256" => sha256(@bootstrap_template)}
  end

  @spec revalidate_manifest(map(), map()) :: :ok | {:error, atom()}
  def revalidate_manifest(root, terminal) do
    with :ok <- validate_root(root),
         {:ok, descriptor} <- file(root, @manifest),
         :ok <- terminal_manifest_descriptor(terminal, descriptor),
         {:ok, bytes} <- File.read(Path.join(root["path"], @manifest)),
         {:ok, manifest} <- Jason.decode(bytes),
         true <- CanonicalValue.encode!(manifest) == bytes,
         :ok <- manifest_shape(manifest),
         :ok <- manifest_digest(manifest, terminal),
         :ok <- artifact_identity(manifest, terminal),
         :ok <- artifact_tree(root, manifest),
         :ok <- manifest_members(root, manifest),
         :ok <- manifest_edges(root, manifest) do
      :ok
    else
      _ -> {:error, :manifest_changed}
    end
  rescue
    _ -> {:error, :manifest_changed}
  end

  defp terminal_manifest_descriptor(%{"manifest" => expected}, actual) do
    if expected == actual, do: :ok, else: {:error, :manifest_descriptor}
  end

  defp terminal_manifest_descriptor(_terminal, _actual), do: :ok

  defp valid_manifest_base?(base, producer_kinds) do
    exact?(
      base,
      ~w[rekindle_version application_id target build producer host_requirements hot_styles]
    ) and
      valid_semver?(base["rekindle_version"]) and
      valid_application_id?(base["application_id"]) and
      base["target"] == "web" and
      valid_manifest_build?(base["build"]) and
      valid_web_producer?(base["producer"], producer_kinds) and
      base["host_requirements"] == %{"secure_context" => true, "webgpu" => true} and
      relative_strings_sorted_unique?(base["hot_styles"], true)
  end

  defp valid_manifest_build?(build) do
    exact?(build, ~w[build_key profile package binary features]) and
      digest?(build["build_key"]) and
      Enum.all?(~w[profile package binary], &cargo_identifier?(build[&1])) and
      valid_feature_list?(build["features"])
  end

  defp valid_feature_list?(features) do
    is_list(features) and length(features) <= 128 and features == Enum.sort(features) and
      unique?(features) and Enum.all?(features, &cargo_identifier?/1) and
      Enum.reduce_while(features, 0, fn feature, total ->
        case total + byte_size(feature) do
          total when total <= 8_192 -> {:cont, total}
          _total -> {:halt, :overflow}
        end
      end) != :overflow
  end

  defp cargo_identifier?(value) when is_binary(value) do
    byte_size(value) in 1..128 and
      Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E))
  end

  defp cargo_identifier?(_value), do: false

  defp valid_web_producer?(%{"kind" => "canonical_web"} = producer, producer_kinds) do
    "canonical_web" in producer_kinds and
      exact?(
        producer,
        ~w[kind rustc cargo rust_target wasm_bindgen gpui_revision helper_version helper_protocol compatibility_tuple_id]
      ) and
      producer["helper_protocol"] == 1 and
      Enum.all?(~w[rustc cargo], fn key ->
        manifest_string?(producer[key])
      end) and
      cargo_identifier?(producer["rust_target"]) and
      valid_gpui_revision?(producer["gpui_revision"]) and
      digest?(producer["compatibility_tuple_id"]) and
      valid_semver?(producer["wasm_bindgen"]) and valid_semver?(producer["helper_version"])
  end

  defp valid_web_producer?(%{"kind" => "extension"} = producer, producer_kinds) do
    "extension" in producer_kinds and
      exact?(producer, ~w[kind backend_id backend_version options_digest]) and
      valid_backend_id?(producer["backend_id"]) and
      valid_backend_version?(producer["backend_version"]) and
      digest?(producer["options_digest"])
  end

  defp valid_web_producer?(_producer, _producer_kinds), do: false

  defp valid_semver?(value) when is_binary(value) do
    manifest_string?(value) and match?({:ok, %Version{}}, Version.parse(value))
  end

  defp valid_semver?(_value), do: false

  defp valid_gpui_revision?(value),
    do: is_binary(value) and Regex.match?(@gpui_revision_pattern, value)

  defp valid_application_id?(value),
    do: is_binary(value) and Regex.match?(@application_id_pattern, value)

  defp valid_backend_id?(value),
    do: is_binary(value) and Regex.match?(@backend_id_pattern, value)

  defp valid_backend_version?(value) do
    is_binary(value) and byte_size(value) in 1..128 and
      Enum.all?(:binary.bin_to_list(value), &(&1 <= 0x7F))
  end

  defp manifest_string?(value) when is_binary(value) do
    value != "" and byte_size(value) <= @max_manifest_string_bytes and String.valid?(value) and
      String.normalize(value, :nfc) == value and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/u)
  end

  defp manifest_string?(_value), do: false

  defp relative_strings_sorted_unique?(values, allow_empty?, validator \\ &relative?/1) do
    is_list(values) and (allow_empty? or values != []) and values == Enum.sort(values) and
      unique?(values) and Enum.all?(values, validator)
  end

  defp member_metadata(role, path) when is_binary(path) do
    extension = path |> case_fold() |> Path.extname()

    case {role, extension} do
      {"bootstrap", ".js"} ->
        {:ok, "text/javascript; charset=utf-8", "no_cache"}

      {"javascript", ".js"} ->
        {:ok, "text/javascript; charset=utf-8", "immutable"}

      {"wasm", ".wasm"} ->
        {:ok, "application/wasm", "immutable"}

      {"css", ".css"} ->
        {:ok, "text/css; charset=utf-8", "immutable"}

      {"source_map", ".map"} ->
        {:ok, "application/json; charset=utf-8", "immutable"}

      {"asset", extension} when extension not in [".js", ".wasm", ".css", ".map"] ->
        {:ok, asset_mime(extension), "immutable"}

      _ ->
        {:error, :role_extension}
    end
  end

  defp member_metadata(_role, _path), do: {:error, :role_extension}

  defp asset_mime(extension) do
    Map.get(
      %{
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".avif" => "image/avif",
        ".svg" => "image/svg+xml",
        ".ico" => "image/x-icon",
        ".woff" => "font/woff",
        ".woff2" => "font/woff2",
        ".ttf" => "font/ttf",
        ".otf" => "font/otf",
        ".txt" => "text/plain; charset=utf-8",
        ".json" => "application/json; charset=utf-8"
      },
      extension,
      "application/octet-stream"
    )
  end

  defp case_fold(value) when is_binary(value) do
    value |> String.to_charlist() |> :string.casefold() |> List.to_string()
  end

  defp manifest_shape(manifest) do
    keys =
      ~w[contract_version rekindle_version application_id target artifact_id build producer host_requirements entry hot_styles members edges manifest_digest]

    base =
      Map.take(
        manifest,
        ~w[rekindle_version application_id target build producer host_requirements hot_styles]
      )

    if exact?(manifest, keys) and manifest["contract_version"] == 1 and
         valid_manifest_base?(base, ~w[canonical_web extension]) and
         digest?(manifest["artifact_id"]) and digest?(manifest["manifest_digest"]) and
         relative?(manifest["entry"]) and is_list(manifest["members"]) and
         manifest["members"] != [] and is_list(manifest["edges"]) and
         valid_manifest_members_shape?(manifest),
       do: :ok,
       else: {:error, :manifest_shape}
  end

  defp valid_manifest_members_shape?(manifest) do
    members = manifest["members"]
    paths = Enum.map(members, & &1["path"])
    folded_paths = Enum.map(paths, &case_fold/1)
    roles = Map.new(members, &{&1["path"], &1["role"]})

    paths == Enum.sort(paths) and length(paths) == MapSet.size(MapSet.new(paths)) and
      length(folded_paths) == MapSet.size(MapSet.new(folded_paths)) and
      Enum.all?(members, &valid_manifest_member_shape?/1) and
      Enum.count(members, &(&1["role"] == "bootstrap")) == 1 and
      roles[manifest["entry"]] == "bootstrap" and
      Enum.all?(manifest["hot_styles"], &(roles[&1] == "css"))
  rescue
    _ -> false
  end

  defp valid_manifest_member_shape?(member) do
    with true <- exact?(member, ~w[path role sha256 size mime cache source_map]),
         true <- relative?(member["path"]),
         {:ok, mime, cache} <- member_metadata(member["role"], member["path"]),
         true <- member["mime"] == mime and member["cache"] == cache,
         true <- digest?(member["sha256"]) and nonnegative?(member["size"]),
         true <- is_nil(member["source_map"]) or relative?(member["source_map"]) do
      true
    else
      _ -> false
    end
  end

  defp manifest_digest(manifest, terminal) do
    recorded = manifest["manifest_digest"]

    calculated =
      domain_digest("rekindle-web-manifest-v1\0", Map.delete(manifest, "manifest_digest"))

    if recorded == calculated and terminal["manifest_digest"] == calculated,
      do: :ok,
      else: {:error, :manifest_digest}
  end

  defp artifact_identity(manifest, terminal) do
    members =
      Enum.map(manifest["members"], &Map.take(&1, ~w[path role sha256 size]))

    identity = %{
      "v" => 1,
      "build_key" => manifest["build"]["build_key"],
      "members" => members
    }

    calculated = domain_digest("rekindle-web-artifact-v1\0", identity)

    if manifest["artifact_id"] == calculated and terminal["artifact_id"] == calculated,
      do: :ok,
      else: {:error, :artifact_identity}
  end

  defp artifact_tree(root, manifest) do
    expected =
      Enum.reduce(manifest["members"], artifact_root_nodes(), fn member, nodes ->
        path = member["path"]

        nodes = Map.put(nodes, "members/" <> path, :regular)

        path
        |> String.split("/")
        |> Enum.drop(-1)
        |> Enum.scan("", fn segment, prefix ->
          if prefix == "", do: segment, else: prefix <> "/" <> segment
        end)
        |> Enum.reduce(nodes, fn directory, nodes ->
          Map.put(nodes, "members/" <> directory, :directory)
        end)
      end)

    with {:ok, root_stat} <- File.lstat(root["path"]),
         true <- root_stat.type == :directory,
         true <- root["device"] == device_identity(root_stat),
         {:ok, actual} <- artifact_nodes(root["path"]),
         true <- actual == expected,
         :ok <- artifact_marker(root, root_stat) do
      :ok
    else
      _ -> {:error, :artifact_tree}
    end
  end

  defp artifact_root_nodes do
    %{
      @marker => :regular,
      @manifest => :regular,
      "members" => :directory
    }
  end

  defp artifact_nodes(root), do: artifact_nodes(root, "", %{})

  defp artifact_nodes(path, prefix, nodes) do
    with {:ok, entries} <- File.ls(path) do
      Enum.reduce_while(entries, {:ok, nodes}, fn entry, {:ok, nodes} ->
        relative = if prefix == "", do: entry, else: prefix <> "/" <> entry
        child = Path.join(path, entry)

        case File.lstat(child) do
          {:ok, %{type: :regular}} ->
            {:cont, {:ok, Map.put(nodes, relative, :regular)}}

          {:ok, %{type: :directory}} ->
            case artifact_nodes(child, relative, Map.put(nodes, relative, :directory)) do
              {:ok, nodes} -> {:cont, {:ok, nodes}}
              {:error, _reason} = error -> {:halt, error}
            end

          _ ->
            {:halt, {:error, :non_regular_node}}
        end
      end)
    end
  end

  defp artifact_marker(root, root_stat) do
    path = Path.join(root["path"], @marker)

    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.uid == root_stat.uid,
         true <- stat.major_device == root_stat.major_device,
         true <- stat.minor_device == root_stat.minor_device,
         true <- Bitwise.band(stat.mode, 0o777) == 0o600,
         {:ok, bytes} <- File.read(path),
         {:ok, marker} <- Jason.decode(bytes),
         true <- CanonicalValue.encode!(marker) == bytes,
         true <- exact?(marker, ~w[root_id v]),
         true <- marker["v"] == 1,
         true <- marker["root_id"] == root["id"] do
      :ok
    else
      _ -> {:error, :invalid_marker}
    end
  end

  defp device_identity(stat),
    do: stat.major_device * 4_294_967_296 + stat.minor_device

  defp manifest_members(root, manifest) do
    members = manifest["members"]
    paths = Enum.map(members, & &1["path"])
    folded_paths = Enum.map(paths, &case_fold/1)
    roles = Map.new(members, &{&1["path"], &1["role"]})

    cond do
      paths != Enum.sort(paths) or length(paths) != MapSet.size(MapSet.new(paths)) or
          length(folded_paths) != MapSet.size(MapSet.new(folded_paths)) ->
        {:error, :member_order}

      not Enum.all?(members, &valid_manifest_member?(root, &1)) ->
        {:error, :member_changed}

      Enum.count(members, &(&1["role"] == "bootstrap")) != 1 or
          roles[manifest["entry"]] != "bootstrap" ->
        {:error, :member_entry}

      not Enum.all?(manifest["hot_styles"], &(roles[&1] == "css")) ->
        {:error, :hot_style_member}

      true ->
        :ok
    end
  end

  defp valid_manifest_member?(root, member) do
    with true <- valid_manifest_member_shape?(member),
         {:ok, descriptor} <- file(root, "members/" <> member["path"]),
         true <- descriptor["sha256"] == member["sha256"],
         true <- descriptor["size"] == member["size"] do
      true
    else
      _ -> false
    end
  end

  defp manifest_edges(root, manifest) do
    roles = Map.new(manifest["members"], &{&1["path"], &1["role"]})

    with {:ok, expected_edges, source_maps} <- derive_graph(root, manifest, roles),
         true <- manifest["edges"] == expected_edges,
         true <-
           Enum.all?(manifest["members"], fn member ->
             member["source_map"] == Map.get(source_maps, member["path"])
           end),
         [javascript] <-
           Enum.filter(expected_edges, fn edge ->
             edge["from"] == manifest["entry"] and edge["kind"] == "dynamic_import"
           end),
         true <- roles[javascript["to"]] == "javascript",
         true <- required_graph_members?(roles, expected_edges) do
      :ok
    else
      _ -> {:error, :invalid_edges}
    end
  end

  defp derive_graph(root, manifest, roles) do
    initial =
      Enum.reduce(manifest["hot_styles"], MapSet.new(), fn path, edges ->
        MapSet.put(edges, {manifest["entry"], path, "css_url"})
      end)

    Enum.reduce_while(roles, {:ok, initial, %{}}, fn {path, role}, {:ok, edges, maps} ->
      parser =
        case role do
          role when role in ["javascript", "bootstrap"] -> &javascript_references/1
          "css" -> &css_references/1
          _ -> fn _ -> {:ok, []} end
        end

      with {:ok, bytes} <- File.read(Path.join([root["path"], "members", path])),
           {:ok, references} <- parser.(bytes),
           {:ok, next_edges, next_maps} <-
             resolve_graph_references(path, references, roles, edges, maps) do
        {:cont, {:ok, next_edges, next_maps}}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
    |> case do
      {:ok, edges, maps} ->
        edges =
          edges
          |> MapSet.to_list()
          |> Enum.sort()
          |> Enum.map(fn {from, to, kind} -> %{"from" => from, "to" => to, "kind" => kind} end)

        if Enum.all?(edges, &valid_graph_edge?(&1, roles)),
          do: {:ok, edges, maps},
          else: {:error, :invalid_graph}

      error ->
        error
    end
  end

  defp resolve_graph_references(path, references, roles, edges, maps) do
    Enum.reduce_while(references, {:ok, edges, maps}, fn {specifier, kind, module?},
                                                         {:ok, edges, maps} ->
      with {:ok, target} <- resolve_reference(path, specifier, module?),
           true <- String.starts_with?(target, "https://") or Map.has_key?(roles, target),
           {:ok, maps} <- put_source_map(maps, path, target, kind) do
        {:cont, {:ok, MapSet.put(edges, {path, target, kind}), maps}}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
  end

  defp put_source_map(maps, _path, _target, kind) when kind != "source_map", do: {:ok, maps}

  defp put_source_map(maps, path, target, "source_map") do
    case Map.fetch(maps, path) do
      :error -> {:ok, Map.put(maps, path, target)}
      {:ok, ^target} -> {:ok, maps}
      {:ok, _other} -> {:error, :multiple_source_maps}
    end
  end

  defp valid_graph_edge?(edge, roles) do
    exact?(edge, ~w[from to kind]) and Map.has_key?(roles, edge["from"]) and
      (Map.has_key?(roles, edge["to"]) or valid_https_url?(edge["to"])) and
      edge["kind"] in ~w[esm_import dynamic_import wasm_url source_map css_url asset_url]
  end

  defp required_graph_members?(roles, edges) do
    Enum.all?(roles, fn {path, role} ->
      required =
        if role == "wasm", do: "wasm_url", else: if(role == "source_map", do: "source_map")

      is_nil(required) or Enum.any?(edges, &(&1["to"] == path and &1["kind"] == required))
    end)
  end

  defp resolve_reference(from, specifier, module?) do
    cond do
      valid_https_url?(specifier) ->
        {:ok, specifier}

      not is_binary(specifier) or specifier == "" or
        String.starts_with?(specifier, ["https:", "//", "/"]) or
        String.contains?(specifier, [":", "\\", <<0>>, "?", "#", "%"]) or
          String.match?(specifier, ~r/\s/u) ->
        {:error, :forbidden_reference}

      module? and not String.starts_with?(specifier, "./") ->
        {:error, :bare_import}

      true ->
        relative =
          if String.starts_with?(specifier, "./"),
            do: binary_part(specifier, 2, byte_size(specifier) - 2),
            else: specifier

        segments = String.split(relative, "/")

        if relative == "" or Enum.any?(segments, &(&1 in ["", ".", ".."])) do
          {:error, :invalid_reference}
        else
          parent = Path.dirname(from)
          {:ok, if(parent == ".", do: relative, else: parent <> "/" <> relative)}
        end
    end
  end

  defp valid_https_url?(value) when is_binary(value) do
    case String.split(value, "/", parts: 4) do
      ["https:", "", authority | _] when authority != "" ->
        not String.contains?(value, ["\\", <<0>>, "\"", "'", "<", ">"]) and
          not String.match?(value, ~r/\s/u)

      _ ->
        false
    end
  end

  defp valid_https_url?(_value), do: false

  defp javascript_references(bytes) when is_binary(bytes) do
    with true <- String.valid?(bytes),
         {:ok, tokens, comments} <- javascript_tokens(bytes),
         {:ok, references} <- javascript_token_references(tokens, nil, []) do
      comment_references =
        Enum.flat_map(comments, fn comment ->
          case source_map_reference(comment) do
            nil -> []
            specifier -> [{specifier, "source_map", false}]
          end
        end)

      {:ok, references ++ comment_references}
    else
      _ -> {:error, :invalid_javascript}
    end
  end

  defp javascript_tokens(bytes), do: javascript_tokens(bytes, [], [])

  defp javascript_tokens(<<>>, tokens, comments),
    do: {:ok, Enum.reverse(tokens), Enum.reverse(comments)}

  defp javascript_tokens(<<byte, rest::binary>>, tokens, comments)
       when byte in [9, 10, 12, 13, 32],
       do: javascript_tokens(rest, tokens, comments)

  defp javascript_tokens(<<"//", rest::binary>>, tokens, comments) do
    {comment, rest} = take_until_line_end(rest)
    javascript_tokens(rest, tokens, ["//" <> comment | comments])
  end

  defp javascript_tokens(<<"/*", rest::binary>>, tokens, comments) do
    case take_until_marker(rest, "*/") do
      {:ok, comment, rest} ->
        javascript_tokens(rest, tokens, ["/*" <> comment <> "*/" | comments])

      :error ->
        {:error, :unterminated_comment}
    end
  end

  defp javascript_tokens(<<?/, rest::binary>>, tokens, comments) do
    if regex_literal_allowed?(tokens) do
      case take_regex_literal(rest, false) do
        {:ok, rest} -> javascript_tokens(rest, [:regex | tokens], comments)
        :error -> {:error, :unterminated_regex}
      end
    else
      javascript_tokens(rest, ["/" | tokens], comments)
    end
  end

  defp javascript_tokens(<<quote, rest::binary>>, tokens, comments) when quote in [?", ?'] do
    case take_quoted(rest, quote, [], false) do
      {:ok, value, escaped?, rest} ->
        token = {:string, if(escaped?, do: :escaped, else: value)}
        javascript_tokens(rest, [token | tokens], comments)

      :error ->
        {:error, :unterminated_string}
    end
  end

  defp javascript_tokens(<<?`, rest::binary>>, tokens, comments) do
    with {:ok, expressions, rest} <- take_template(rest, []),
         {:ok, tokens, comments} <- tokenize_template_expressions(expressions, tokens, comments) do
      javascript_tokens(rest, [:template | tokens], comments)
    else
      _ -> {:error, :unterminated_template}
    end
  end

  defp javascript_tokens(<<byte, _rest::binary>> = bytes, tokens, comments)
       when byte in ?A..?Z or byte in ?a..?z or byte in [?_, ?$] do
    {identifier, rest} = take_identifier(bytes, [])
    javascript_tokens(rest, [{:id, identifier} | tokens], comments)
  end

  defp javascript_tokens(<<codepoint::utf8, rest::binary>>, tokens, comments),
    do: javascript_tokens(rest, [<<codepoint::utf8>> | tokens], comments)

  defp javascript_token_references([], _previous, references),
    do: {:ok, Enum.reverse(references)}

  defp javascript_token_references(
         [
           {:id, "new"},
           {:id, "URL"},
           "(",
           {:string, specifier},
           ",",
           {:id, "import"},
           ".",
           {:id, "meta"},
           ".",
           {:id, "url"},
           ")" | rest
         ],
         _previous,
         references
       ) do
    with {:ok, specifier} <- literal_specifier(specifier) do
      kind =
        if reference_path(specifier) |> String.ends_with?(".wasm"),
          do: "wasm_url",
          else: "asset_url"

      javascript_token_references(rest, ")", [{specifier, kind, false} | references])
    end
  end

  defp javascript_token_references(
         [{:id, "import"}, "(" | rest],
         previous,
         references
       )
       when previous not in [".", "#"] do
    if method_definition_tail?(rest) do
      javascript_token_references(["(" | rest], {:id, "import"}, references)
    else
      dynamic_import_reference(rest, references)
    end
  end

  defp javascript_token_references(
         [{:id, "import"}, {:string, _specifier} | _rest] = tokens,
         previous,
         references
       )
       when previous not in [".", "#"],
       do: static_import_reference(tokens, references)

  defp javascript_token_references(
         [{:id, "import"}, {:id, _binding} | _rest] = tokens,
         previous,
         references
       )
       when previous not in [".", "#"],
       do: static_import_reference(tokens, references)

  defp javascript_token_references(
         [{:id, "import"}, form | _rest] = tokens,
         previous,
         references
       )
       when previous not in [".", "#"] and form in ["*", "{"],
       do: static_import_reference(tokens, references)

  defp javascript_token_references([{:id, "export"}, form | rest], previous, references)
       when previous not in [".", "#"] and form in ["{", "*"] do
    with {:ok, specifier} <- static_module_specifier([form | rest], :export) do
      references =
        if is_nil(specifier), do: references, else: [{specifier, "esm_import", true} | references]

      javascript_token_references([form | rest], {:id, "export"}, references)
    end
  end

  defp javascript_token_references([token | rest], _previous, references),
    do: javascript_token_references(rest, token, references)

  defp dynamic_import_reference([{:string, specifier}, ")" | rest], references) do
    with {:ok, specifier} <- literal_specifier(specifier) do
      javascript_token_references(
        rest,
        ")",
        [{specifier, "dynamic_import", true} | references]
      )
    end
  end

  defp dynamic_import_reference(_tokens, _references), do: {:error, :nonliteral_dynamic_import}

  defp static_import_reference([{:id, "import"} | rest], references) do
    with {:ok, specifier} <- static_module_specifier(rest, :import) do
      references =
        if is_nil(specifier), do: references, else: [{specifier, "esm_import", true} | references]

      javascript_token_references(rest, {:id, "import"}, references)
    end
  end

  defp method_definition_tail?(tokens), do: method_definition_tail?(tokens, 1)
  defp method_definition_tail?([], _depth), do: false
  defp method_definition_tail?(["(" | rest], depth), do: method_definition_tail?(rest, depth + 1)
  defp method_definition_tail?([")", "{" | _rest], 1), do: true
  defp method_definition_tail?([")" | _rest], 1), do: false
  defp method_definition_tail?([")" | rest], depth), do: method_definition_tail?(rest, depth - 1)
  defp method_definition_tail?([_token | rest], depth), do: method_definition_tail?(rest, depth)

  defp static_module_specifier([{:string, specifier} | _rest], :import),
    do: literal_specifier(specifier)

  defp static_module_specifier(tokens, _kind), do: find_from_specifier(tokens)

  defp find_from_specifier([]), do: {:ok, nil}
  defp find_from_specifier([";" | _rest]), do: {:ok, nil}

  defp find_from_specifier([{:id, "from"}, {:string, specifier} | _rest]),
    do: literal_specifier(specifier)

  defp find_from_specifier([{:id, "from"} | _rest]), do: {:error, :nonliteral_import}
  defp find_from_specifier([_token | rest]), do: find_from_specifier(rest)

  defp literal_specifier(value) when is_binary(value), do: {:ok, value}
  defp literal_specifier(_value), do: {:error, :escaped_reference}

  defp regex_literal_allowed?([]), do: true

  defp regex_literal_allowed?([previous | _rest])
       when previous in [
              "(",
              "[",
              "{",
              ",",
              ";",
              ":",
              "=",
              "!",
              "?",
              "&",
              "|",
              "+",
              "-",
              "*",
              "%",
              "^",
              "~",
              "<",
              ">"
            ],
       do: true

  defp regex_literal_allowed?([{:id, keyword} | _rest])
       when keyword in ~w[return throw case delete void typeof instanceof in of yield await else do default new extends],
       do: true

  defp regex_literal_allowed?([")" | rest]), do: control_condition?(rest, 1)

  defp regex_literal_allowed?(_tokens), do: false

  defp control_condition?([], _depth), do: false
  defp control_condition?([")" | rest], depth), do: control_condition?(rest, depth + 1)

  defp control_condition?(["(" | [{:id, keyword} | _rest]], 1),
    do: keyword in ~w[if while for with switch catch]

  defp control_condition?(["(" | rest], depth), do: control_condition?(rest, depth - 1)
  defp control_condition?([_token | rest], depth), do: control_condition?(rest, depth)

  defp take_regex_literal(<<>>, _character_class?), do: :error

  defp take_regex_literal(<<byte, _rest::binary>>, _character_class?) when byte in [?\n, ?\r],
    do: :error

  defp take_regex_literal(<<?\\, _byte, rest::binary>>, character_class?),
    do: take_regex_literal(rest, character_class?)

  defp take_regex_literal(<<?[, rest::binary>>, false), do: take_regex_literal(rest, true)
  defp take_regex_literal(<<?], rest::binary>>, true), do: take_regex_literal(rest, false)

  defp take_regex_literal(<<?/, rest::binary>>, false) do
    {_flags, rest} = take_identifier(rest, [])
    {:ok, rest}
  end

  defp take_regex_literal(<<_byte, rest::binary>>, character_class?),
    do: take_regex_literal(rest, character_class?)

  defp css_references(bytes) when is_binary(bytes) do
    if String.valid?(bytes), do: css_references(bytes, false, []), else: {:error, :invalid_css}
  end

  defp css_references(_bytes), do: {:error, :invalid_css}

  defp css_references(<<>>, _previous_name?, references), do: {:ok, Enum.reverse(references)}

  defp css_references(<<"/*", rest::binary>>, _previous_name?, references) do
    case take_until_marker(rest, "*/") do
      {:ok, comment, rest} ->
        references =
          case source_map_reference("/*" <> comment <> "*/") do
            nil -> references
            specifier -> [{specifier, "source_map", false} | references]
          end

        css_references(rest, false, references)

      :error ->
        {:error, :unterminated_comment}
    end
  end

  defp css_references(<<quote, rest::binary>>, _previous_name?, references)
       when quote in [?", ?'] do
    case take_quoted(rest, quote, [], false) do
      {:ok, _value, _escaped?, rest} -> css_references(rest, false, references)
      :error -> {:error, :unterminated_string}
    end
  end

  defp css_references(bytes, false, references) do
    cond do
      css_keyword?(bytes, "@import") ->
        rest = bytes |> binary_part(7, byte_size(bytes) - 7) |> trim_ascii_space()

        with {:ok, specifier, rest} <- css_import_value(rest) do
          css_references(rest, false, [{specifier, "css_url", false} | references])
        end

      css_keyword?(bytes, "url") ->
        rest = bytes |> binary_part(3, byte_size(bytes) - 3) |> trim_ascii_space()

        with {:ok, specifier, rest} <- css_url_value(rest) do
          css_references(rest, false, [{specifier, "asset_url", false} | references])
        end

      true ->
        css_advance(bytes, references)
    end
  end

  defp css_references(bytes, _previous_name?, references), do: css_advance(bytes, references)

  defp css_advance(<<byte, rest::binary>>, references) when byte < 128,
    do: css_references(rest, css_name_byte?(byte), references)

  defp css_advance(<<_codepoint::utf8, rest::binary>>, references),
    do: css_references(rest, true, references)

  defp css_import_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    case take_quoted(rest, quote, [], false) do
      {:ok, value, false, rest} -> {:ok, value, rest}
      _ -> {:error, :invalid_css_import}
    end
  end

  defp css_import_value(bytes) do
    if css_keyword?(bytes, "url") do
      bytes
      |> binary_part(3, byte_size(bytes) - 3)
      |> trim_ascii_space()
      |> css_url_value()
    else
      {:error, :invalid_css_import}
    end
  end

  defp css_url_value(<<?(, rest::binary>>) do
    rest = trim_ascii_space(rest)

    case rest do
      <<quote, quoted::binary>> when quote in [?", ?'] ->
        with {:ok, value, false, rest} <- take_quoted(quoted, quote, [], false),
             rest <- trim_ascii_space(rest),
             <<?), rest::binary>> <- rest do
          {:ok, value, rest}
        else
          _ -> {:error, :invalid_css_url}
        end

      _ ->
        case :binary.match(rest, ")") do
          {position, 1} ->
            value = rest |> binary_part(0, position) |> String.trim()
            tail = binary_part(rest, position + 1, byte_size(rest) - position - 1)

            if value != "" and not String.contains?(value, ["\\", "'", "\"", "("]),
              do: {:ok, value, tail},
              else: {:error, :invalid_css_url}

          :nomatch ->
            {:error, :invalid_css_url}
        end
    end
  end

  defp css_url_value(_bytes), do: {:error, :invalid_css_url}

  defp css_keyword?(bytes, keyword) when byte_size(bytes) >= byte_size(keyword) do
    prefix = binary_part(bytes, 0, byte_size(keyword))
    suffix = binary_part(bytes, byte_size(keyword), byte_size(bytes) - byte_size(keyword))

    String.downcase(prefix, :ascii) == keyword and
      case suffix do
        <<byte, _rest::binary>> -> not css_name_byte?(byte)
        <<>> -> true
      end
  end

  defp css_keyword?(_bytes, _keyword), do: false

  defp css_name_byte?(byte),
    do: byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?-]

  defp take_template(<<>>, _expressions), do: :error

  defp take_template(<<?\\, _byte, rest::binary>>, expressions),
    do: take_template(rest, expressions)

  defp take_template(<<?`, rest::binary>>, expressions),
    do: {:ok, Enum.reverse(expressions), rest}

  defp take_template(<<"${", rest::binary>>, expressions) do
    with {:ok, expression, nested, rest} <- take_template_expression(rest, 1, [], []) do
      take_template(rest, Enum.reverse(nested, [expression | expressions]))
    end
  end

  defp take_template(<<_codepoint::utf8, rest::binary>>, expressions),
    do: take_template(rest, expressions)

  defp take_template_expression(<<>>, _depth, _chunks, _nested), do: :error

  defp take_template_expression(<<"//", rest::binary>>, depth, chunks, nested) do
    {comment, rest} = take_until_line_end(rest)
    take_template_expression(rest, depth, [["//", comment, "\n"] | chunks], nested)
  end

  defp take_template_expression(<<"/*", rest::binary>>, depth, chunks, nested) do
    case take_until_marker(rest, "*/") do
      {:ok, comment, rest} ->
        take_template_expression(rest, depth, [["/*", comment, "*/"] | chunks], nested)

      :error ->
        :error
    end
  end

  defp take_template_expression(<<quote, rest::binary>>, depth, chunks, nested)
       when quote in [?", ?'] do
    case take_quoted(rest, quote, [], false) do
      {:ok, value, _escaped?, rest} ->
        take_template_expression(rest, depth, [[<<quote>>, value, <<quote>>] | chunks], nested)

      :error ->
        :error
    end
  end

  defp take_template_expression(<<?`, rest::binary>>, depth, chunks, nested) do
    with {:ok, expressions, rest} <- take_template(rest, []) do
      take_template_expression(rest, depth, ["``" | chunks], Enum.reverse(expressions, nested))
    end
  end

  defp take_template_expression(<<?/, rest::binary>>, depth, chunks, nested) do
    if template_regex_allowed?(chunks) do
      case take_regex_literal(rest, false) do
        {:ok, rest} -> take_template_expression(rest, depth, ["/(?:)/" | chunks], nested)
        :error -> :error
      end
    else
      take_template_expression(rest, depth, ["/" | chunks], nested)
    end
  end

  defp take_template_expression(<<?{, rest::binary>>, depth, chunks, nested),
    do: take_template_expression(rest, depth + 1, ["{" | chunks], nested)

  defp take_template_expression(<<?}, rest::binary>>, 1, chunks, nested),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), nested, rest}

  defp take_template_expression(<<?}, rest::binary>>, depth, chunks, nested),
    do: take_template_expression(rest, depth - 1, ["}" | chunks], nested)

  defp take_template_expression(<<codepoint::utf8, rest::binary>>, depth, chunks, nested),
    do: take_template_expression(rest, depth, [<<codepoint::utf8>> | chunks], nested)

  defp tokenize_template_expressions(expressions, tokens, comments) do
    Enum.reduce_while(expressions, {:ok, tokens, comments}, fn expression,
                                                               {:ok, tokens, comments} ->
      case javascript_tokens(expression) do
        {:ok, expression_tokens, expression_comments} ->
          {:cont,
           {:ok, Enum.reverse(expression_tokens, tokens),
            Enum.reverse(expression_comments, comments)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp template_regex_allowed?(chunks) do
    partial = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case javascript_tokens(partial) do
      {:ok, tokens, _comments} -> regex_literal_allowed?(Enum.reverse(tokens))
      {:error, _reason} -> false
    end
  end

  defp take_identifier(<<byte, rest::binary>>, bytes)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?$],
       do: take_identifier(rest, [byte | bytes])

  defp take_identifier(rest, bytes),
    do: {bytes |> Enum.reverse() |> :erlang.list_to_binary(), rest}

  defp take_quoted(<<>>, _quote, _bytes, _escaped?), do: :error

  defp take_quoted(<<?\\, byte, rest::binary>>, quote, bytes, _escaped?),
    do: take_quoted(rest, quote, [byte, ?\\ | bytes], true)

  defp take_quoted(<<quote, rest::binary>>, quote, bytes, escaped?),
    do: {:ok, bytes |> Enum.reverse() |> :erlang.list_to_binary(), escaped?, rest}

  defp take_quoted(<<byte, rest::binary>>, quote, bytes, escaped?),
    do: take_quoted(rest, quote, [byte | bytes], escaped?)

  defp take_until_line_end(bytes) do
    case :binary.match(bytes, ["\n", "\r"]) do
      {position, 1} ->
        {binary_part(bytes, 0, position),
         binary_part(bytes, position + 1, byte_size(bytes) - position - 1)}

      :nomatch ->
        {bytes, <<>>}
    end
  end

  defp take_until_marker(bytes, marker) do
    case :binary.match(bytes, marker) do
      {position, size} ->
        {:ok, binary_part(bytes, 0, position),
         binary_part(bytes, position + size, byte_size(bytes) - position - size)}

      :nomatch ->
        :error
    end
  end

  defp source_map_reference(comment) do
    content =
      comment
      |> String.trim_leading("//")
      |> String.trim_leading("/*")
      |> String.trim_trailing("*/")
      |> String.trim()

    case content do
      "# sourceMappingURL=" <> value -> nonempty_trim(value)
      "@ sourceMappingURL=" <> value -> nonempty_trim(value)
      _ -> nil
    end
  end

  defp nonempty_trim(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp reference_path(value), do: value |> String.split(["?", "#"], parts: 2) |> hd()

  defp trim_ascii_space(<<byte, rest::binary>>) when byte in [9, 10, 12, 13, 32],
    do: trim_ascii_space(rest)

  defp trim_ascii_space(bytes), do: bytes

  defp domain_digest(domain, value),
    do:
      :crypto.hash(:sha256, [domain, CanonicalValue.encode!(value)])
      |> Base.encode16(case: :lower)

  defp progress(state, header) do
    diagnostic = header["diagnostic"]

    if Map.keys(header) |> Enum.sort() ==
         Enum.sort(~w[v type request_id payload_len sequence diagnostic]) and
         header["sequence"] == state.progress_sequence and valid_diagnostic?(diagnostic) do
      {:ok, %{state | progress_sequence: state.progress_sequence + 1}, diagnostic}
    else
      {:error, :invalid_progress}
    end
  end

  defp terminal_ok(state, header) do
    if header["op"] == state.op and valid_success?(state.op, header) do
      {:terminal, header, %{state | terminal?: true}}
    else
      {:error, :invalid_operation_success}
    end
  end

  defp terminal_error(state, header) do
    diagnostics = header["diagnostics"]

    if Map.keys(header) |> Enum.sort() ==
         Enum.sort(~w[v type request_id payload_len op code message diagnostics]) and
         header["op"] == state.op and header["code"] in @error_codes and
         is_binary(header["message"]) and
         is_list(diagnostics) and Enum.all?(diagnostics, &valid_diagnostic?/1) do
      {:terminal, header, %{state | terminal?: true}}
    else
      {:error, :invalid_operation_error}
    end
  end

  defp valid_success?("bindgen_web", header) do
    exact?(header, ~w[v type request_id payload_len op files javascript_entry wasm]) and
      files?(header["files"]) and relative?(header["javascript_entry"]) and
      relative?(header["wasm"]) and file_path?(header["files"], header["javascript_entry"]) and
      file_path?(header["files"], header["wasm"])
  end

  defp valid_success?("package_web", header) do
    exact?(
      header,
      ~w[v type request_id payload_len op files manifest artifact_id manifest_digest]
    ) and
      files?(header["files"]) and file_descriptor?(header["manifest"]) and
      header["manifest"] in header["files"] and
      digest?(header["artifact_id"]) and digest?(header["manifest_digest"])
  end

  defp valid_success?("verify_web", header) do
    exact?(
      header,
      ~w[v type request_id payload_len op artifact_id manifest_digest members_verified total_bytes]
    ) and
      digest?(header["artifact_id"]) and digest?(header["manifest_digest"]) and
      nonnegative?(header["members_verified"]) and nonnegative?(header["total_bytes"])
  end

  defp validate_operation("bindgen_web", body) do
    if exact?(
         body,
         ~w[input_root input_wasm output_root output_stem debug source_maps expected_wasm_bindgen limits]
       ) and
         read_root?(body["input_root"]) and file_descriptor?(body["input_wasm"]) and
         body["input_wasm"]["root_id"] == body["input_root"]["id"] and
         write_root?(body["output_root"]) and
         is_binary(body["output_stem"]) and body["output_stem"] != "" and
         is_boolean(body["debug"]) and
         body["source_maps"] in ~w[none external] and is_binary(body["expected_wasm_bindgen"]) and
         limits?(body["limits"]),
       do: :ok,
       else: {:error, :invalid_operation}
  end

  defp validate_operation("package_web", body) do
    if exact?(
         body,
         ~w[bindgen_root bindgen_files public_root public_files bootstrap_template output_root manifest_base limits]
       ) and
         read_root?(body["bindgen_root"]) and files?(body["bindgen_files"]) and
         files_belong_to?(body["bindgen_files"], body["bindgen_root"]) and
         (is_nil(body["public_root"]) or read_root?(body["public_root"])) and
         files?(body["public_files"]) and
         public_files_belong_to_root?(body["public_files"], body["public_root"]) and
         exact?(body["bootstrap_template"], ~w[id sha256]) and write_root?(body["output_root"]) and
         valid_manifest_base?(body["manifest_base"], ["canonical_web"]) and
         limits?(body["limits"]),
       do: :ok,
       else: {:error, :invalid_operation}
  end

  defp validate_operation("verify_web", body) do
    if exact?(body, ~w[artifact_root manifest expected_manifest_digest limits]) and
         read_root?(body["artifact_root"]) and
         file_descriptor?(body["manifest"]) and digest?(body["expected_manifest_digest"]) and
         body["manifest"]["root_id"] == body["artifact_root"]["id"] and
         limits?(body["limits"]),
       do: :ok,
       else: {:error, :invalid_operation}
  end

  defp validate_root(root) do
    if exact?(root, @root_keys) and request_id(root["id"]) == :ok and
         Path.type(root["path"] || "") == :absolute and
         root["mode"] in ~w[read write_empty] and nonnegative?(root["device"]),
       do: :ok,
       else: {:error, :invalid_root}
  end

  defp read_root?(root), do: validate_root(root) == :ok and root["mode"] == "read"
  defp write_root?(root), do: validate_root(root) == :ok and root["mode"] == "write_empty"

  defp limits?(limits),
    do:
      exact?(limits, @limit_keys) and Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0))

  defp file_descriptor?(file) do
    exact?(file, @file_keys) and request_id(file["root_id"]) == :ok and relative?(file["path"]) and
      digest?(file["sha256"]) and nonnegative?(file["size"]) and
      file["mode"] in ~w[data executable]
  end

  defp files?(files),
    do:
      is_list(files) and files == Enum.sort_by(files, & &1["path"]) and
        unique?(Enum.map(files, & &1["path"])) and Enum.all?(files, &file_descriptor?/1)

  defp files_belong_to?(files, root),
    do: Enum.all?(files, &(&1["root_id"] == root["id"]))

  defp public_files_belong_to_root?([], nil), do: true

  defp public_files_belong_to_root?(files, root) when is_map(root),
    do: files_belong_to?(files, root)

  defp public_files_belong_to_root?(_files, _root), do: false

  defp file_path?(files, path), do: Enum.any?(files, &(&1["path"] == path))

  defp validate_descriptors(root, files) do
    if Enum.all?(files, fn descriptor ->
         descriptor["root_id"] == root["id"] and
           match?(
             {:ok, ^descriptor},
             file(root, descriptor["path"], String.to_existing_atom(descriptor["mode"]))
           )
       end), do: :ok, else: {:error, :descriptor_changed}
  end

  defp actual_files(root, allow_marker?) do
    paths =
      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(allow_marker? and &1 == @marker))
      |> Enum.sort()

    {:ok, paths}
  end

  defp validate_empty(_path, :read, _id, _root_stat), do: :ok

  defp validate_empty(path, :write_empty, id, root_stat) do
    marker = Path.join(path, @marker)

    with {:ok, [@marker]} <- File.ls(path),
         {:ok, stat} <- File.lstat(marker),
         true <- stat.type == :regular and stat.uid == root_stat.uid,
         true <- Bitwise.band(stat.mode, 0o777) == 0o600,
         true <- stat.major_device == root_stat.major_device,
         {:ok, bytes} <- File.read(marker),
         true <- bytes == marker_bytes(id) do
      :ok
    else
      _ -> {:error, :invalid_marker}
    end
  end

  defp create_marker(path, bytes) do
    case File.write(path, bytes, [:binary, :exclusive]) do
      :ok -> File.chmod(path, 0o600)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp marker_bytes(id), do: CanonicalValue.encode!(%{"root_id" => id, "v" => 1})

  defp valid_diagnostic?(value) do
    exact?(value, ~w[severity code message path line]) and value["severity"] in ~w[info warning] and
      is_binary(value["code"]) and is_binary(value["message"]) and
      byte_size(value["message"]) <= 8_192 and
      (is_nil(value["path"]) or relative?(value["path"])) and
      (is_nil(value["line"]) or nonnegative?(value["line"]))
  end

  defp relative?(value), do: relative_path(value) == :ok

  defp relative_path(value) when is_binary(value) do
    segments = String.split(value, "/")

    if value != "" and byte_size(value) <= @max_path_bytes and Path.type(value) != :absolute and
         String.valid?(value) and
         String.normalize(value, :nfc) == value and
         not String.contains?(value, ["\\", <<0>>]) and
         not String.match?(value, ~r/[\x00-\x1F\x7F]/u) and
         Enum.all?(segments, &(&1 not in ["", ".", ".."])), do: :ok, else: {:error, :path}
  end

  defp relative_path(_), do: {:error, :path}
  defp contained?(path, root), do: path != root and String.starts_with?(path, root <> "/")

  defp request_id(value) when is_binary(value),
    do: if(Regex.match?(~r/\A[0-9a-f]{32}\z/, value), do: :ok, else: {:error, :id})

  defp request_id(_), do: {:error, :id}
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp nonnegative?(value), do: is_integer(value) and value >= 0
  defp exact?(map, keys), do: is_map(map) and Map.keys(map) |> Enum.sort() == Enum.sort(keys)
  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(values))
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp stringify(value), do: value
end
