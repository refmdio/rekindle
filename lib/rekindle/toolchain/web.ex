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
    const module = await import("./__REKINDLE_ENTRY__");
    await module.default();
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
         :ok <- validate_empty(path, mode) do
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
         :ok <- manifest_members(root, manifest),
         :ok <- manifest_edges(manifest) do
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

  defp manifest_shape(manifest) do
    keys =
      ~w[contract_version rekindle_version application_id target artifact_id build producer host_requirements entry hot_styles members edges manifest_digest]

    if exact?(manifest, keys) and manifest["contract_version"] == 1 and
         manifest["target"] == "web" and digest?(manifest["artifact_id"]) and
         digest?(manifest["manifest_digest"]) and is_list(manifest["members"]) and
         is_list(manifest["edges"]),
       do: :ok,
       else: {:error, :manifest_shape}
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

  defp manifest_members(root, manifest) do
    members = manifest["members"]
    paths = Enum.map(members, & &1["path"])

    cond do
      paths != Enum.sort(paths) or length(paths) != MapSet.size(MapSet.new(paths)) ->
        {:error, :member_order}

      not Enum.all?(members, &valid_manifest_member?(root, &1)) ->
        {:error, :member_changed}

      true ->
        actual =
          root["path"]
          |> Path.join("members/**/*")
          |> Path.wildcard(match_dot: true)
          |> Enum.reject(&File.dir?/1)
          |> Enum.map(&Path.relative_to(&1, Path.join(root["path"], "members")))
          |> Enum.sort()

        if actual == paths, do: :ok, else: {:error, :member_closure}
    end
  end

  defp valid_manifest_member?(root, member) do
    with true <-
           exact?(member, ~w[path role sha256 size mime cache source_map]) and
             member["role"] in ~w[bootstrap javascript wasm css asset source_map] and
             member["cache"] in ~w[no_cache immutable] and digest?(member["sha256"]),
         {:ok, descriptor} <- file(root, "members/" <> member["path"]),
         true <- descriptor["sha256"] == member["sha256"],
         true <- descriptor["size"] == member["size"] do
      true
    else
      _ -> false
    end
  end

  defp manifest_edges(manifest) do
    member_paths = MapSet.new(manifest["members"], & &1["path"])

    valid? =
      Enum.all?(manifest["edges"], fn edge ->
        exact?(edge, ~w[from to kind]) and MapSet.member?(member_paths, edge["from"]) and
          MapSet.member?(member_paths, edge["to"]) and
          edge["kind"] in ~w[esm_import dynamic_import wasm_url source_map css_url asset_url]
      end)

    if valid?, do: :ok, else: {:error, :invalid_edges}
  end

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
      relative?(header["wasm"])
  end

  defp valid_success?("package_web", header) do
    exact?(
      header,
      ~w[v type request_id payload_len op files manifest artifact_id manifest_digest]
    ) and
      files?(header["files"]) and file_descriptor?(header["manifest"]) and
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
         (is_nil(body["public_root"]) or read_root?(body["public_root"])) and
         files?(body["public_files"]) and
         exact?(body["bootstrap_template"], ~w[id sha256]) and write_root?(body["output_root"]) and
         is_map(body["manifest_base"]) and limits?(body["limits"]),
       do: :ok,
       else: {:error, :invalid_operation}
  end

  defp validate_operation("verify_web", body) do
    if exact?(body, ~w[artifact_root manifest expected_manifest_digest limits]) and
         read_root?(body["artifact_root"]) and
         file_descriptor?(body["manifest"]) and digest?(body["expected_manifest_digest"]) and
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

  defp validate_empty(_path, :read), do: :ok

  defp validate_empty(path, :write_empty) do
    case File.ls(path) do
      {:ok, []} -> :ok
      {:ok, [@marker]} -> :ok
      _ -> {:error, :not_empty}
    end
  end

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

    if value != "" and Path.type(value) != :absolute and String.valid?(value) and
         String.normalize(value, :nfc) == value and
         not String.contains?(value, ["\\", <<0>>]) and
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
