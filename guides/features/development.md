# Development

Rekindle runs the Cargo build and development lifecycle from Mix. Cargo remains
the source of truth for Rust dependencies and incremental compilation.

## Prepare the project

The installer adds the required Rust tooling setup to the Phoenix project's
standard setup alias:

```console
mix setup
```

Run Rekindle setup directly to prepare one target without the rest of the
project setup:

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
mix phx.server
```

Files below `client/` are watched and rebuilt through Cargo. A successful Web
build publishes an immutable development generation for the polling browser
runtime. For a desktop replacement, Rekindle stops the current process before
starting the replacement. If the replacement exits, Rekindle reports the exit
and waits for the next successful build.

Rekindle's supervised development services run only when the Phoenix endpoint
has code reloading enabled.

## Build explicitly

Build an enabled target without starting its development runtime:

```console
mix rekindle.build web
mix rekindle.build desktop
```

Development artifacts and state are stored below `.rekindle/dev`.
