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
├── public/
└── src/
    ├── lib.rs
    └── bin/
        ├── web.rs
        └── desktop.rs
```

The application owns and edits this project. Rekindle does not hide it behind a
global cache or a generated dependency.

Shared UI and application logic belongs in `client/src/lib.rs`. The binaries
under `client/src/bin` select the browser or native platform and call the shared
code. Cargo features let one crate include only the platform dependencies
required for each target.

## Development and release

In development, Rekindle watches `client/`, schedules Cargo builds, and replaces
only successful Web generations or desktop processes. Phoenix and the Rust UI
therefore share one supervised development command.

For production, Rekindle runs the configured Cargo release profile and
publishes an immutable Web generation or a content-addressed desktop executable.
The resulting artifacts belong to the host application's ordinary deployment
or packaging process.
