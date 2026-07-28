# Rekindle

Rekindle brings Cargo-based Rust UI builds into Elixir applications. Mix is the
entry point for installation, development, Web packaging, and native release
artifacts, while Cargo continues to manage Rust dependencies, compilation,
target directories, and incremental caches.

GPUI, egui/eframe, Slint, and Iced are supported. Each plugin can generate a
browser target compiled to WebAssembly, a native desktop target, or both from
a shared Rust UI crate.

## Requirements

- Elixir 1.17 or later
- Rust and Cargo
- The Rust targets and native system libraries required by the selected UI
  plugin

## Create a project

Install the Igniter and Phoenix project generators:

```console
mix archive.install hex igniter_new
mix archive.install hex phx_new
```

Create a Phoenix application with a GPUI client for Web and desktop:

```console
mix igniter.new my_app \
  --with phx.new \
  --install rekindle \
  --plugin gpui \
  --targets web,desktop
```

Then prepare the project and start Phoenix:

```console
cd my_app
mix setup
mix phx.server
```

See the
[Getting Started guide](guides/introduction/getting-started.md) for existing
Phoenix applications and the remaining setup options. Read the complete guides
and API documentation on [HexDocs](https://rekindle.hexdocs.pm).

## License

Rekindle is available under the MIT License.
