# Rekindle

Rekindle brings Cargo-based Rust UI builds into Elixir and Phoenix projects.
Mix is the entry point for installation, development, Web packaging, and native
release artifacts, while Cargo continues to manage Rust dependencies,
compilation, target directories, and incremental caches.

GPUI, egui/eframe, and Slint are supported. Each integration can generate a
browser target compiled to WebAssembly, a native desktop target, or both from a
shared Rust UI crate.

## Requirements

- Elixir 1.17 or later
- Rust and Cargo
- A Phoenix project generator
- The Rust targets and native system libraries required by the selected UI
  integration

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
  --integration gpui \
  --targets web,desktop
```

Then prepare the required tools and start development:

```console
cd my_app
mix rekindle.setup
mix rekindle.dev
```

See the
[Getting Started guide](guides/introduction/getting-started.md) for existing
Phoenix applications and the remaining setup options. Complete guides and API
documentation are published on [HexDocs](https://rekindle.hexdocs.pm).

## License

Rekindle is available under the MIT License.
