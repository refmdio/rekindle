# Rekindle

Rekindle brings Cargo-based Rust UI builds into Elixir and Phoenix projects.
Mix is the entry point for installation, development, Web packaging, and native
release artifacts. Cargo remains responsible for Rust dependencies,
compilation, target directories, and incremental caches.

Rekindle includes project templates for GPUI, egui/eframe, and Slint. Each
integration supports a browser target compiled to WebAssembly and a native
desktop target.

## Requirements

- Elixir 1.17 or later
- A Phoenix application with an endpoint
- Rust and Cargo
- Igniter 0.8 or later as a development dependency
- The Rust targets and native system libraries required by the selected UI
  integration

`wasm-bindgen-cli` is installed into Rekindle's versioned user cache by the
setup command. A global installation is not required.

## Installation

Add Igniter to the Phoenix application's development dependencies:

```elixir
def deps do
  [
    {:igniter, "~> 0.8", only: [:dev, :test]}
  ]
end
```

Fetch Igniter, then use it to add and install Rekindle:

```console
mix deps.get
mix igniter.install rekindle --integration gpui --targets web,desktop
```

Valid integrations are `gpui`, `egui`, and `slint`. Valid target selections are
`web`, `desktop`, and `web,desktop`. When flags are omitted for a new client,
Rekindle generates GPUI entries for both targets.

The installer creates an application-owned Cargo project:

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

Shared UI and application logic belongs in `client/src/lib.rs`. The target
entries select the browser or native platform and call that shared code.

The generated Elixir configuration has this shape:

```elixir
config :my_app, Rekindle,
  integration: :gpui,
  targets: [
    web: [features: ["web"]],
    desktop: [features: ["desktop"]]
  ]
```

Use `public_dir: "path/to/static"` to publish Web releases outside the default
`priv/static` directory. The path must remain inside the project.

### Adopting an existing client

If `client/Cargo.toml` already exists, Rekindle does not replace it. Supply both
the integration and target selection:

```console
mix igniter.install rekindle --integration egui --targets web,desktop
```

The selected target entries must already exist under `client/src/bin`.

## Tool setup and diagnostics

Prepare the tools required by all enabled targets:

```console
mix rekindle.setup
```

Limit setup to one target when needed:

```console
mix rekindle.setup web
mix rekindle.setup desktop
```

Inspect configuration, Cargo, target support, the selected integration, and
the pinned Web tool without changing the project:

```console
mix rekindle.doctor
```

## Development

Start Phoenix together with Rekindle's supervised development services:

```console
mix rekindle.dev
```

Files below `client/` are watched and rebuilt through Cargo. Web builds publish
an immutable generation and notify the browser after a successful build.
Desktop builds start the new executable only after it is ready; a failed
replacement leaves the last working process available. Development services
run only when the Phoenix endpoint has code reloading enabled.

The installer adds the development Web plug and the Rekindle supervisor to the
Phoenix application. Arguments passed to `mix rekindle.dev` are forwarded to
`mix phx.server`.

## Explicit builds

Build one enabled target without starting it:

```console
mix rekindle.build web
mix rekindle.build desktop
```

Development artifacts are stored below `.rekindle/dev`. Add `--release` to use
the target's release Cargo profile and publish a production artifact:

```console
mix rekindle.build web --release
mix rekindle.build desktop --release
```

### Web releases

Web releases are published below
`priv/static/rekindle/web/<generation>/` by default. A
`priv/static/rekindle/web-current.json` selector points to the complete current
generation. The installer prepends the Web release build to `assets.deploy`, so
publication finishes before `phx.digest`, and adds a static endpoint at
`/rekindle`.

Web execution requirements are determined by the selected integration and the
browser. Browser APIs such as WebGPU can require a secure context when accessed
from another device; use HTTPS for deployed applications and remote
development.

### Desktop releases

Desktop releases are published by Rust target:

```text
dist/rekindle/<rust-target>/<binary>-<sha256>
dist/rekindle/<rust-target>/manifest.json
```

The manifest identifies the exact executable, target, package, binary, and
content hash. A release build packages the executable but never launches it.

## Elixir API

The Mix task and programmatic API use the same build pipeline:

```elixir
{:ok, result} =
  Rekindle.build(:web,
    otp_app: :my_app,
    profile: :release
  )

result.artifact
result.metadata.manifest
```

`Rekindle.build/2` returns typed errors rather than raising for configuration,
Cargo, toolchain, and publication failures.

## License

Rekindle is available under the MIT License.
