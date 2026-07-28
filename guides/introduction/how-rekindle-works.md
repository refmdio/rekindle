# How Rekindle Works

Rekindle makes Mix the entry point for a Rust UI project without replacing
Cargo. Elixir owns installation, target selection, development supervision, and
artifact publication. Cargo owns Rust dependencies, compilation, profiles,
target directories, and incremental caches.

## Application-owned client

Installation creates a Cargo project inside the Elixir application:

```text
client/
├── Cargo.toml
├── rust-toolchain.toml
├── build.rs             # Slint build script, when selected
├── public/
├── ui/                  # Slint UI sources, when selected
└── src/
    ├── app.rs           # eframe application, when selected
    ├── lib.rs
    └── bin/
        ├── web.rs
        └── desktop.rs
```

The application owns and edits this project. Rekindle does not hide it behind a
global cache or a generated dependency.

Shared UI and application logic remains outside the target binaries. GPUI keeps
it in `client/src/lib.rs`, eframe uses `client/src/app.rs`, and Slint uses
`client/ui/app-window.slint` with bindings in `client/src/lib.rs`. The binaries
under `client/src/bin` select the browser or native platform and call that
shared code. Cargo features let one crate include only the platform dependencies
required for each target.

## Development and release

In development, Rekindle owns the client watcher, Cargo builders, and selected
target runtime. The `Rekindle.DevServer` Plug starts Web development on the
first request and serves successful generations, so the normal Phoenix command
remains `mix phx.server`. `mix rekindle.dev` provides the same runtime without
an HTTP server and is the entry point for desktop development, which starts and
replaces the selected native process.

For production, Rekindle runs the configured Cargo release profile and
publishes an immutable Web generation or a desktop executable and manifest.
The resulting artifacts belong to the host application's ordinary deployment
or packaging process.
