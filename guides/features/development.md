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

Run the project's standard precommit checks, including Rust formatting, Clippy,
and library tests:

```console
mix precommit
```

Run only the Rust checks with `mix rekindle.check`. Web library tests are
compiled but not executed because browser test runners are application-specific.

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

Phoenix logs the start and completion time of each Rust build. While the first
Web build is running, the browser shows a loading status; build and graphics
startup failures are shown in the page without discarding the last successful
generation.

Before a newer Web generation reloads the page, the runtime dispatches
`rekindle:before-reload` on `window`. Applications may use this event to save
serializable development state. It dispatches `rekindle:ready` after startup
and `rekindle:error` when a build or startup fails. These hooks do not preserve
state automatically.

Rekindle's supervised development services run only when the Phoenix endpoint
has code reloading enabled.

## Build explicitly

Build all Phoenix assets, including the Rekindle Web target:

```console
mix assets.build
```

Build an enabled target without starting its development runtime:

```console
mix rekindle.build web
mix rekindle.build desktop
```

Development artifacts and state are stored below `.rekindle/dev`.
