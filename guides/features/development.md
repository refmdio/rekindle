# Development

Rekindle runs the Cargo build and development lifecycle from Mix. Cargo remains
the source of truth for Rust dependencies and incremental compilation.

## Prepare tools

Prepare every enabled target:

```console
mix rekindle.setup
```

Limit setup to one target when necessary:

```console
mix rekindle.setup web
mix rekindle.setup desktop
```

For Web builds, Rekindle installs the pinned `wasm-bindgen-cli` release into a
versioned user cache. A global installation is not required.

## Check the project

Run the read-only diagnostic task:

```console
mix rekindle.doctor
```

It checks the Rekindle configuration, Cargo metadata, target support, selected
integration, and pinned Web tooling.

## Start development

Start Phoenix and the Rekindle development services together:

```console
mix rekindle.dev
```

Arguments are passed through to `mix phx.server`.

Files below `client/` are watched and rebuilt through Cargo. A successful Web
build publishes an immutable development generation and notifies connected
browsers. A successful desktop build starts the replacement executable only
after it is ready. Failed replacements leave the last working desktop process
available.

Rekindle's supervised development services run only when the Phoenix endpoint
has code reloading enabled.

## Build explicitly

Build an enabled target without starting its development runtime:

```console
mix rekindle.build web
mix rekindle.build desktop
```

Development artifacts and state are stored below `.rekindle/dev`.
