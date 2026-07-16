defmodule Rekindle.ClientGenerator do
  @moduledoc false

  alias Rekindle.CanonicalValue

  @template_version "1"
  @client_version "0.1.0"
  @gpui_revision "18f35ffac2da72ccdfb0e1bf756218fa1995162b"
  @web_toolchain "nightly-2026-04-01"

  @spec render(keyword()) :: %{required(String.t()) => binary()}
  def render(options) do
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

    owned_paths = [
      "Cargo.toml",
      "rust-toolchain.toml",
      ".cargo/config.toml",
      "src/lib.rs",
      "src/bin/web.rs",
      "src/bin/desktop.rs"
    ]

    marker_base = %{
      "schema" => 1,
      "template_version" => @template_version,
      "application_id" => application_id,
      "package" => package,
      "web_binary" => web_binary,
      "desktop_binary" => desktop_binary,
      "gpui_revision" => @gpui_revision,
      "rekindle_client_version" => @client_version,
      "targets" => Enum.map(targets, &Atom.to_string/1),
      "owned_files" =>
        Enum.map(owned_paths, fn path ->
          %{"path" => path, "template_sha256" => sha256(Map.fetch!(files, path))}
        end)
    }

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
      case System.cmd(
             "cargo",
             ["generate-lockfile", "--manifest-path", Path.join(client_root, "Cargo.toml")],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> raise "cargo generate-lockfile failed (#{status}): #{output}"
      end
    end

    written
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

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
