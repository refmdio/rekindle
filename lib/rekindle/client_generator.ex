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
    files = render(options)

    if File.exists?(client_root) and File.ls!(client_root) != [] do
      raise ArgumentError, "client root must not contain existing files"
    end

    written =
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {relative, contents} ->
        path = Path.join(client_root, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents, [:binary, :exclusive])
        path
      end)

    if Keyword.get(options, :generate_lock, true) do
      case generate_lock(client_root) do
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

    written
  end

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
