# Desktop Target

The desktop target compiles and runs the native binary selected from the shared
client crate for the host target reported by `rustc -vV`. Platform support and
required native libraries depend on the selected UI plugin.

## Development

Run `mix rekindle.dev desktop`. Rekindle validates a successful build, stops
the current process, removes its disposable build directory, and starts the
replacement. If the replacement exits, no previous executable is restarted.
HTTP requests never start the desktop target.

Run one build without starting the executable:

```console
mix rekindle.build desktop
```

## Production

```console
mix rekindle.build desktop --release
```

The published layout is:

```text
dist/rekindle/desktop/<rust-target>/application
dist/rekindle/desktop/<rust-target>/manifest.json
```

The manifest identifies the executable, Rust target, selected plugin,
Cargo package, and binary. A release build packages the executable but never
launches it. Use the manifest from an application packager, installer, or
deployment pipeline.

Rekindle does not bundle an Elixir runtime or application release into this
artifact. An application that needs an embedded backend can compose the desktop
artifact with its chosen Elixir distribution approach.
