defmodule Rekindle.ClientGenerator do
  @moduledoc false

  alias Rekindle.CanonicalValue
  alias Rekindle.Toolchain.{Executable, Rustup}

  @template_version "2"
  @client_version "0.1.0"
  @gpui_revision "18f35ffac2da72ccdfb0e1bf756218fa1995162b"
  @web_toolchain "nightly-2026-04-01"
  @marker_keys ~w[schema template_version application_id package web_binary desktop_binary gpui_revision rekindle_client_version owned_files]
  @identity_keys ~w[schema application_id package web_binary desktop_binary gpui_revision rekindle_client_version]
  @prior_template_profiles %{
    {"1", @gpui_revision, @client_version} => :v1
  }
  @owned_paths [
    "Cargo.toml",
    "rust-toolchain.toml",
    ".cargo/config.toml",
    "src/lib.rs",
    "src/bin/web.rs",
    "src/bin/desktop.rs"
  ]
  @application_owned_paths ["Cargo.lock", "src/app.rs", "public/.gitkeep"]

  @spec render(keyword()) :: %{required(String.t()) => binary()}
  def render(options) do
    render_template(options, @template_version)
  end

  @doc false
  @spec render_prior(String.t(), keyword()) :: {:ok, map()} | :error
  def render_prior(version, options) when is_binary(version) do
    with {:ok, identity} <- identity(options),
         profile when not is_nil(profile) <-
           Map.get(
             @prior_template_profiles,
             {version, @gpui_revision, @client_version}
           ) do
      {:ok, render_profile(profile, identity, options)}
    else
      _ -> :error
    end
  end

  @doc false
  @spec recognize_prior(binary(), keyword()) ::
          {:ok, %{marker: map(), files: map(), recorded_digests: map()}} | :error
  def recognize_prior(contents, options) when is_binary(contents) do
    with {:ok, marker} <- Jason.decode(contents),
         true <- exact_marker?(marker),
         true <- CanonicalValue.encode!(marker) <> "\n" == contents,
         {:ok, known_files} <- render_prior(marker["template_version"], options),
         {:ok, identity} <- identity(options),
         true <- marker_identity(marker) == identity,
         {:ok, recorded_digests} <- recorded_digests(marker, known_files),
         true <- valid_marker_seed_digest?(marker) do
      {:ok, %{marker: marker, files: known_files, recorded_digests: recorded_digests}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def recognize_prior(_contents, _options), do: :error

  defp render_template(options, template_version) do
    application_id = Keyword.fetch!(options, :application_id)
    package = Keyword.get(options, :package, application_id <> "_ui")
    web_binary = Keyword.get(options, :web_binary, application_id <> "-web")
    desktop_binary = Keyword.get(options, :desktop_binary, application_id)
    targets = Keyword.get(options, :targets, [:web, :desktop])
    dependency = Keyword.get(options, :rekindle_client, {:version, @client_version})
    crate = String.replace(package, "-", "_")

    validate!(application_id, package, web_binary, desktop_binary, targets)

    files = %{
      "Cargo.toml" => cargo_toml(package, web_binary, desktop_binary, dependency),
      "Cargo.lock" => "",
      "rust-toolchain.toml" => rust_toolchain(),
      ".cargo/config.toml" => cargo_config(),
      "src/app.rs" => app_rs(),
      "src/lib.rs" => lib_rs(application_id),
      "src/bin/web.rs" => web_rs(crate),
      "src/bin/desktop.rs" => desktop_rs(crate),
      "public/.gitkeep" => ""
    }

    identity = %{
      "schema" => 1,
      "application_id" => application_id,
      "package" => package,
      "web_binary" => web_binary,
      "desktop_binary" => desktop_binary,
      "gpui_revision" => @gpui_revision,
      "rekindle_client_version" => @client_version
    }

    put_marker(files, identity, template_version)
  end

  # Version 1 owns its own renderer. Do not share owned template functions with
  # the current renderer: their bytes are the compatibility registry.
  defp render_profile(:v1, identity, options) do
    package = identity["package"]
    crate = String.replace(package, "-", "_")
    dependency = Keyword.get(options, :rekindle_client, {:version, @client_version})

    files = %{
      "Cargo.toml" =>
        prior_v1_cargo_toml(
          package,
          identity["web_binary"],
          identity["desktop_binary"],
          dependency
        ),
      "Cargo.lock" => "",
      "rust-toolchain.toml" => prior_v1_rust_toolchain(),
      ".cargo/config.toml" => prior_v1_cargo_config(),
      "src/app.rs" => app_rs(),
      "src/lib.rs" => prior_v1_lib_rs(identity["application_id"]),
      "src/bin/web.rs" => prior_v1_web_rs(crate),
      "src/bin/desktop.rs" => prior_v1_desktop_rs(crate),
      "public/.gitkeep" => ""
    }

    put_marker(files, identity, "1")
  end

  defp put_marker(files, identity, template_version) do
    marker_base =
      identity
      |> Map.put("template_version", template_version)
      |> Map.put(
        "owned_files",
        Enum.map(@owned_paths, fn path ->
          %{"path" => path, "template_sha256" => sha256(Map.fetch!(files, path))}
        end)
      )

    marker_seed = CanonicalValue.encode!(marker_base) <> "\n"

    marker =
      Map.update!(marker_base, "owned_files", fn entries ->
        entries ++
          [
            %{
              "path" => ".rekindle-client.json",
              "template_sha256" => sha256(marker_seed)
            }
          ]
      end)

    Map.put(files, ".rekindle-client.json", CanonicalValue.encode!(marker) <> "\n")
  end

  defp identity(options) do
    application_id = Keyword.fetch!(options, :application_id)
    package = Keyword.get(options, :package, application_id <> "_ui")
    web_binary = Keyword.get(options, :web_binary, application_id <> "-web")
    desktop_binary = Keyword.get(options, :desktop_binary, application_id)
    targets = Keyword.get(options, :targets, [:web, :desktop])

    validate!(application_id, package, web_binary, desktop_binary, targets)

    {:ok,
     %{
       "schema" => 1,
       "application_id" => application_id,
       "package" => package,
       "web_binary" => web_binary,
       "desktop_binary" => desktop_binary,
       "gpui_revision" => @gpui_revision,
       "rekindle_client_version" => @client_version
     }}
  rescue
    _ -> :error
  end

  defp marker_identity(marker), do: Map.take(marker, @identity_keys)

  defp exact_marker?(marker),
    do: is_map(marker) and Enum.sort(Map.keys(marker)) == Enum.sort(@marker_keys)

  defp recorded_digests(marker, known_files) do
    expected_paths =
      known_files[".rekindle-client.json"]
      |> Jason.decode!()
      |> Map.fetch!("owned_files")
      |> Enum.map(& &1["path"])

    entries = marker["owned_files"]

    if is_list(entries) and Enum.map(entries, & &1["path"]) == expected_paths do
      Enum.reduce_while(entries, {:ok, %{}}, fn
        %{"path" => path, "template_sha256" => digest}, {:ok, acc}
        when is_binary(path) and is_binary(digest) ->
          if path in expected_paths and valid_sha256?(digest) and not Map.has_key?(acc, path) do
            {:cont, {:ok, Map.put(acc, path, digest)}}
          else
            {:halt, :error}
          end

        _, _acc ->
          {:halt, :error}
      end)
      |> case do
        {:ok, digests} when map_size(digests) == length(expected_paths) -> {:ok, digests}
        _ -> :error
      end
    else
      :error
    end
  end

  defp valid_marker_seed_digest?(marker) do
    case Enum.find(marker["owned_files"], &(&1["path"] == ".rekindle-client.json")) do
      %{"template_sha256" => digest} ->
        marker_base =
          Map.update!(marker, "owned_files", fn entries ->
            Enum.reject(entries, &(&1["path"] == ".rekindle-client.json"))
          end)

        digest == sha256(CanonicalValue.encode!(marker_base) <> "\n")

      _ ->
        false
    end
  end

  defp valid_sha256?(value),
    do: is_binary(value) and byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]{64}\z/

  @spec write!(Path.t(), keyword()) :: [Path.t()]
  def write!(client_root, options) do
    client_root = Path.expand(client_root)
    files = render(options)
    parent = Path.dirname(client_root)

    ensure_directory!(parent)

    case admit_root(client_root) do
      :ok -> :ok
      {:error, _reason} -> raise ArgumentError, "client root is not a no-follow directory path"
    end

    if directory?(client_root) and File.ls!(client_root) != [] do
      raise ArgumentError, "client root must not contain existing files"
    end

    parent_identity = directory_identity!(parent)
    staging = client_root <> ".rekindle-stage-" <> random_id()
    File.mkdir!(staging)
    staging_identity = directory_identity!(staging)

    try do
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(fn {relative, contents} ->
        revalidate_directory!(staging, staging_identity)
        path = Path.join(staging, relative)
        ensure_directory!(Path.dirname(path), staging, staging_identity)
        File.write!(path, contents, [:binary, :exclusive])
        revalidate_directory!(staging, staging_identity)
      end)

      if Keyword.get(options, :generate_lock, true) do
        case generate_lock(staging) do
          :ok ->
            :ok

          {:error, %Rekindle.Failure{} = failure} ->
            raise failure.message

          {:error, {output, status}} ->
            raise "cargo generate-lockfile failed (#{status}): #{output}"

          {:error, reason} ->
            raise "cargo generate-lockfile failed: #{reason}"
        end
      end

      if hook = Keyword.get(options, :before_publish) do
        hook.(client_root, staging)
      end

      publish_staging!(staging, staging_identity, client_root, parent, parent_identity)

      files
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&Path.join(client_root, &1))
    after
      if lstat_type(staging) in [:directory, :symlink], do: File.rm_rf!(staging)
    end
  end

  @doc false
  @spec reconcile!(Path.t(), keyword(), keyword()) :: [Path.t()]
  def reconcile!(client_root, options, runtime_options \\ []) do
    client_root = Path.expand(client_root)
    files = render(options)
    parent = Path.dirname(client_root)

    ensure_directory!(parent)

    case admit_root(client_root) do
      :ok -> :ok
      {:error, _reason} -> raise ArgumentError, "client root is not a no-follow directory path"
    end

    parent_identity = directory_identity!(parent)
    {existing_files, existing_directories, client_identity} = snapshot_client!(client_root)
    reconciled_files = reconcile_files!(existing_files, files, options)
    staging = client_root <> ".rekindle-stage-" <> random_id()
    File.mkdir!(staging)
    staging_identity = directory_identity!(staging)

    try do
      existing_directories
      |> Enum.sort_by(&path_depth/1)
      |> Enum.each(fn relative ->
        revalidate_client_snapshot!(client_root, client_identity)
        ensure_directory!(Path.join(staging, relative), staging, staging_identity)
      end)

      reconciled_files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(fn {relative, contents} ->
        revalidate_client_snapshot!(client_root, client_identity)
        revalidate_directory!(staging, staging_identity)
        path = Path.join(staging, relative)
        ensure_directory!(Path.dirname(path), staging, staging_identity)
        File.write!(path, contents, [:binary, :exclusive])
        revalidate_directory!(staging, staging_identity)
      end)

      if Keyword.get(runtime_options, :generate_lock, true) and
           Map.get(reconciled_files, "Cargo.lock") == "" do
        case generate_lock(staging) do
          :ok ->
            :ok

          {:error, %Rekindle.Failure{} = failure} ->
            raise failure.message

          {:error, {output, status}} ->
            raise "cargo generate-lockfile failed (#{status}): #{output}"

          {:error, reason} ->
            raise "cargo generate-lockfile failed: #{reason}"
        end
      end

      if hook = Keyword.get(runtime_options, :before_publish) do
        hook.(client_root, staging)
      end

      publish_reconciled!(
        staging,
        staging_identity,
        client_root,
        client_identity,
        parent,
        parent_identity
      )

      reconciled_files
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&Path.join(client_root, &1))
    after
      if lstat_type(staging) in [:directory, :symlink], do: File.rm_rf!(staging)
    end
  end

  @doc false
  @spec admit_root(Path.t()) :: :ok | {:error, :unsafe_client_root}
  def admit_root(client_root) when is_binary(client_root) do
    client_root
    |> Path.expand()
    |> existing_components()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %{type: :directory}} -> {:cont, :ok}
        {:error, :enoent} -> {:halt, :ok}
        _ -> {:halt, {:error, :unsafe_client_root}}
      end
    end)
  end

  def admit_root(_client_root), do: {:error, :unsafe_client_root}

  defp snapshot_client!(client_root) do
    case File.lstat(client_root) do
      {:error, :enoent} ->
        {%{}, [], nil}

      {:ok, %{type: :directory}} ->
        identity = directory_identity!(client_root)
        {files, directories} = snapshot_directory!(client_root, client_root, identity, "")
        revalidate_directory!(client_root, identity)
        {files, directories, identity}

      _ ->
        raise ArgumentError, "client root is not a no-follow directory path"
    end
  end

  defp snapshot_directory!(path, client_root, client_identity, relative) do
    revalidate_directory!(client_root, client_identity)

    path
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce({%{}, if(relative == "", do: [], else: [relative])}, fn name,
                                                                           {files, directories} ->
      child = Path.join(path, name)
      child_relative = if relative == "", do: name, else: Path.join(relative, name)
      revalidate_directory!(client_root, client_identity)

      case File.lstat(child) do
        {:ok, %{type: :directory}} when relative == "" and name == ".rekindle" ->
          {files, directories}

        {:ok, %{type: :directory}} ->
          {child_files, child_directories} =
            snapshot_directory!(child, client_root, client_identity, child_relative)

          {Map.merge(files, child_files), directories ++ child_directories}

        {:ok, %{type: :regular}} ->
          before = file_identity!(child)
          contents = File.read!(child)

          if file_identity!(child) != before do
            raise ArgumentError, "client file authority changed while reconciling"
          end

          revalidate_directory!(client_root, client_identity)
          {Map.put(files, child_relative, contents), directories}

        _ ->
          raise ArgumentError, "client root contains a symlink or special file"
      end
    end)
  end

  defp reconcile_files!(existing, current, _options) when map_size(existing) == 0,
    do: current

  defp reconcile_files!(existing, current, options) do
    marker = Map.get(existing, ".rekindle-client.json")

    cond do
      marker == current[".rekindle-client.json"] ->
        validate_current_owned_files!(existing, current)
        overlay_generated_files(existing, current)

      true ->
        case recognize_prior(marker, options) do
          {:ok, prior} ->
            validate_prior_owned_files!(existing, prior)
            overlay_generated_files(existing, current)

          :error ->
            raise ArgumentError, "client root is not an admitted Rekindle client"
        end
    end
  end

  defp validate_current_owned_files!(existing, current) do
    Enum.each(@owned_paths, fn relative ->
      if Map.get(existing, relative) != Map.fetch!(current, relative) do
        raise ArgumentError, "Rekindle-owned client file conflicts: #{relative}"
      end
    end)
  end

  defp validate_prior_owned_files!(existing, prior) do
    Enum.each(prior.recorded_digests, fn
      {".rekindle-client.json", _recorded} ->
        :ok

      {relative, recorded} ->
        current_digest = existing |> Map.fetch!(relative) |> sha256()
        known_digest = prior.files |> Map.fetch!(relative) |> sha256()

        if current_digest not in [recorded, known_digest] do
          raise ArgumentError, "Rekindle-owned client file conflicts: #{relative}"
        end
    end)
  rescue
    KeyError -> raise ArgumentError, "Rekindle-owned client file is missing"
  end

  defp overlay_generated_files(existing, current) do
    Enum.reduce(current, existing, fn {relative, contents}, acc ->
      if relative in @application_owned_paths and Map.has_key?(acc, relative) do
        acc
      else
        Map.put(acc, relative, contents)
      end
    end)
  end

  defp publish_reconciled!(
         staging,
         staging_identity,
         client_root,
         client_identity,
         parent,
         parent_identity
       ) do
    revalidate_directory!(parent, parent_identity)
    revalidate_directory!(staging, staging_identity)
    revalidate_client_snapshot!(client_root, client_identity)

    case client_identity do
      nil ->
        File.rename!(staging, client_root)

      _identity ->
        backup = client_root <> ".rekindle-backup-" <> random_id()
        File.rename!(client_root, backup)

        try do
          File.rename!(staging, client_root)
          revalidate_directory!(parent, parent_identity)
          revalidate_directory!(client_root, staging_identity)
        rescue
          error ->
            if lstat_type(client_root) == nil and lstat_type(backup) == :directory do
              File.rename!(backup, client_root)
            end

            reraise error, __STACKTRACE__
        end

        File.rm_rf!(backup)
    end

    revalidate_directory!(parent, parent_identity)
    revalidate_directory!(client_root, staging_identity)
  end

  defp revalidate_client_snapshot!(client_root, nil) do
    if lstat_type(client_root) != nil do
      raise ArgumentError, "client root authority changed before publication"
    end
  end

  defp revalidate_client_snapshot!(client_root, identity),
    do: revalidate_directory!(client_root, identity)

  defp publish_staging!(staging, staging_identity, client_root, parent, parent_identity) do
    revalidate_directory!(parent, parent_identity)
    revalidate_directory!(staging, staging_identity)

    case File.lstat(client_root) do
      {:ok, %{type: :directory}} ->
        if File.ls!(client_root) != [], do: raise(ArgumentError, "client root is no longer empty")

      {:error, :enoent} ->
        :ok

      _ ->
        raise ArgumentError, "client root authority changed before publication"
    end

    revalidate_directory!(parent, parent_identity)
    revalidate_directory!(staging, staging_identity)
    File.rename!(staging, client_root)
    revalidate_directory!(parent, parent_identity)
    revalidate_directory!(client_root, staging_identity)
  end

  defp ensure_directory!(path), do: ensure_directory!(path, nil, nil)

  defp ensure_directory!(path, authority_root, authority_identity) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        parent = Path.dirname(path)
        ensure_directory!(parent, authority_root, authority_identity)
        maybe_revalidate_directory!(authority_root, authority_identity)

        case File.mkdir(path) do
          :ok ->
            :ok

          {:error, :eexist} ->
            :ok

          {:error, reason} ->
            raise File.Error, reason: reason, action: "make directory", path: path
        end

        case File.lstat(path) do
          {:ok, %{type: :directory}} -> :ok
          _ -> raise ArgumentError, "generated client directory authority changed"
        end

        maybe_revalidate_directory!(authority_root, authority_identity)

      _ ->
        raise ArgumentError, "generated client path contains a non-directory component"
    end
  end

  defp maybe_revalidate_directory!(nil, nil), do: :ok

  defp maybe_revalidate_directory!(root, identity),
    do: revalidate_directory!(root, identity)

  defp revalidate_directory!(path, identity) do
    if directory_identity!(path) != identity do
      raise ArgumentError, "generated client directory authority changed"
    end
  end

  defp directory_identity!(path) do
    case File.lstat(path) do
      {:ok, stat = %{type: :directory}} ->
        Map.take(stat, [:inode, :uid, :gid, :major_device, :minor_device, :type, :mode])

      _ ->
        raise ArgumentError, "generated client path is not an admitted directory"
    end
  end

  defp file_identity!(path) do
    case File.lstat(path) do
      {:ok, stat = %{type: :regular}} ->
        Map.take(stat, [
          :inode,
          :uid,
          :gid,
          :major_device,
          :minor_device,
          :type,
          :mode,
          :size,
          :mtime,
          :ctime
        ])

      _ ->
        raise ArgumentError, "client file is not an admitted regular file"
    end
  end

  defp directory?(path), do: lstat_type(path) == :directory

  defp lstat_type(path) do
    case File.lstat(path) do
      {:ok, stat} -> stat.type
      {:error, _reason} -> nil
    end
  end

  defp existing_components(path) do
    path
    |> Path.split()
    |> Enum.scan(fn component, current -> Path.join(current, component) end)
  end

  defp random_id,
    do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp path_depth(path), do: path |> Path.split() |> length()

  @doc false
  @spec generate_lock(Path.t()) ::
          :ok | {:error, Rekindle.Failure.t() | atom() | {binary(), non_neg_integer()}}
  def generate_lock(client_root) do
    manifest = client_root |> Path.expand() |> Path.join("Cargo.toml")

    with {:ok, rustup} <- Rustup.resolve(),
         {:ok, {_output, 0}} <-
           Executable.run(
             rustup,
             [
               "run",
               @web_toolchain,
               "cargo",
               "generate-lockfile",
               "--manifest-path",
               manifest
             ],
             stderr_to_stdout: true
           ) do
      :ok
    else
      {:ok, {output, status}} -> {:error, {output, status}}
      {:error, _reason} = error -> error
    end
  end

  defp validate!(application_id, package, web_binary, desktop_binary, targets) do
    values = [application_id, package, web_binary, desktop_binary]

    unless Enum.all?(
             values,
             &(is_binary(&1) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,127}\z/, &1))
           ) and
             targets != [] and Enum.uniq(targets) == targets and
             Enum.all?(targets, &(&1 in [:web, :desktop])) do
      raise ArgumentError, "invalid generated client identity or targets"
    end
  end

  defp cargo_toml(package, web_binary, desktop_binary, dependency) do
    """
    [package]
    name = #{inspect(package)}
    version = "0.1.0"
    edition = "2024"
    publish = false
    resolver = "2"

    [[bin]]
    name = #{inspect(desktop_binary)}
    path = "src/bin/desktop.rs"
    required-features = ["desktop"]

    [[bin]]
    name = #{inspect(web_binary)}
    path = "src/bin/web.rs"
    required-features = ["web"]

    [features]
    default = []
    web = ["rekindle-client/web"]
    desktop = ["rekindle-client/desktop"]
    state-handoff = ["rekindle-client/state-handoff"]

    [dependencies]
    gpui = { git = "https://github.com/zed-industries/zed", rev = "#{@gpui_revision}", default-features = false }

    [target.'cfg(target_arch = "wasm32")'.dependencies]
    rekindle-client = { #{dependency_toml(dependency)}, features = ["web"] }

    [target.'cfg(not(target_arch = "wasm32"))'.dependencies]
    rekindle-client = { #{dependency_toml(dependency)}, features = ["desktop"] }
    """
  end

  defp dependency_toml({:version, version}), do: "version = \"=#{version}\""
  defp dependency_toml({:path, path}), do: "path = #{inspect(Path.expand(path))}"

  defp rust_toolchain do
    """
    [toolchain]
    channel = "#{@web_toolchain}"
    components = ["rust-src"]
    targets = ["wasm32-unknown-unknown"]
    profile = "minimal"
    """
  end

  defp cargo_config do
    """
    [build]
    target-dir = ".rekindle/target"
    """
  end

  defp app_rs do
    """
    use gpui::prelude::*;
    use gpui::{App, Context, IntoElement, Render, Window, WindowOptions, div};

    struct StarterView;

    impl Render for StarterView {
        fn render(
            &mut self,
            _window: &mut Window,
            _cx: &mut Context<Self>,
        ) -> impl IntoElement {
            div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .child("Rekindle GPUI")
        }
    }

    pub fn build(cx: &mut App) {
        cx.open_window(WindowOptions::default(), |_window, cx| {
            cx.new(|_| StarterView)
        })
        .expect("failed to open the starter GPUI window");
        cx.activate(true);
    }
    """
  end

  defp lib_rs(application_id) do
    """
    pub mod app;

    pub fn client_options() -> rekindle_client::ClientOptions {
        rekindle_client::ClientOptions {
            application_id: #{inspect(application_id)},
            handoff: None,
        }
    }
    """
  end

  defp web_rs(crate) do
    """
    fn main() {
        rekindle_client::web::run(#{crate}::app::build, #{crate}::client_options())
            .expect("failed to start GPUI Web application");
    }
    """
  end

  defp desktop_rs(crate) do
    """
    fn main() {
        rekindle_client::desktop::run(#{crate}::app::build, #{crate}::client_options())
            .expect("failed to start GPUI desktop application");
    }
    """
  end

  defp prior_v1_cargo_toml(package, web_binary, desktop_binary, dependency) do
    """
    [package]
    name = #{inspect(package)}
    version = "0.1.0"
    edition = "2024"
    publish = false
    resolver = "2"

    [[bin]]
    name = #{inspect(desktop_binary)}
    path = "src/bin/desktop.rs"
    required-features = ["desktop"]

    [[bin]]
    name = #{inspect(web_binary)}
    path = "src/bin/web.rs"
    required-features = ["web"]

    [features]
    default = []
    web = ["rekindle-client/web"]
    desktop = ["rekindle-client/desktop"]
    state-handoff = ["rekindle-client/state-handoff"]

    [dependencies]
    gpui = { git = "https://github.com/zed-industries/zed", rev = "18f35ffac2da72ccdfb0e1bf756218fa1995162b", default-features = false }

    [target.'cfg(target_arch = "wasm32")'.dependencies]
    rekindle-client = { #{prior_v1_dependency_toml(dependency)}, features = ["web"] }

    [target.'cfg(not(target_arch = "wasm32"))'.dependencies]
    rekindle-client = { #{prior_v1_dependency_toml(dependency)}, features = ["desktop"] }
    """
  end

  defp prior_v1_dependency_toml({:version, version}), do: "version = \"=#{version}\""
  defp prior_v1_dependency_toml({:path, path}), do: "path = #{inspect(Path.expand(path))}"

  defp prior_v1_rust_toolchain do
    """
    [toolchain]
    channel = "nightly-2026-04-01"
    components = ["rust-src"]
    targets = ["wasm32-unknown-unknown"]
    profile = "minimal"
    """
  end

  defp prior_v1_cargo_config do
    """
    [build]
    target-dir = ".rekindle/target"
    """
  end

  defp prior_v1_lib_rs(application_id) do
    """
    pub mod app;

    pub fn client_options() -> rekindle_client::ClientOptions {
        rekindle_client::ClientOptions {
            application_id: #{inspect(application_id)},
            handoff: None,
        }
    }
    """
  end

  defp prior_v1_web_rs(crate) do
    """
    fn main() {
        rekindle_client::web::run(#{crate}::app::build, #{crate}::client_options())
            .expect("failed to start GPUI Web application");
    }
    """
  end

  defp prior_v1_desktop_rs(crate) do
    """
    fn main() {
        rekindle_client::desktop::run(#{crate}::app::build, #{crate}::client_options())
            .expect("failed to start GPUI desktop application");
    }
    """
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
