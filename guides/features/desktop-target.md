# Desktop Target

The desktop target compiles and runs the native binary selected from the shared
client crate. Rekindle 0.1 supports desktop builds on
`x86_64-unknown-linux-gnu`. Other native targets are not qualified and are
rejected with a diagnostic instead of producing an untested release artifact.

## Development

`mix rekindle.dev` builds the desktop target after client changes. Rekindle
starts a replacement executable only after a successful build. If compilation
or startup fails, the last working process remains available.

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
dist/rekindle/desktop/<rust-target>/<binary>-<sha256>
dist/rekindle/desktop/<rust-target>/manifest.json
```

The manifest identifies the executable, Rust target, selected integration,
Cargo package, binary, and content hash. A release build packages the executable but never launches it.
Use the manifest from an application packager, installer, or deployment
pipeline.

Rekindle does not bundle an Elixir runtime or application release into this
artifact. An application that needs an embedded backend can compose the desktop
artifact with its chosen Elixir distribution approach.
